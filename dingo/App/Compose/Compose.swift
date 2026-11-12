import AppKit
import DingoKit
import Eucalyptus
import SwiftUI
import UniformTypeIdentifiers

/// What a compose window starts from.
enum ComposeStart {
    case new(to: [EmailAddress] = [], subject: String = "", body: String = "")
    case reply(MailMessage, all: Bool)
    case forward(MailMessage)
}

/// Opens compose windows and the original-message viewer.
@MainActor
enum Compose {
    private static var windows: [ComposeWindowController] = []

    static func open(_ start: ComposeStart) {
        guard let from = AppServices.shared.defaultSender(for: start) else {
            NSApp.sendAction(#selector(AppDelegate.addAccount(_:)), to: nil, from: nil)
            return
        }
        let controller = ComposeWindowController(draft: ComposeDraft(start: start, from: from))
        controller.onClose = { [weak controller] in windows.removeAll { $0 === controller } }
        windows.append(controller)
        controller.showWindow(nil)
    }

    /// mailto:a@b.com?subject=Hi&cc=c@d.com&body=…
    static func open(mailto url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let to = AddressParser.parse(components?.path.removingPercentEncoding ?? "")
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name.lowercased() == name }?.value }
        open(.new(to: to + AddressParser.parse(value("to") ?? ""), subject: value("subject") ?? "", body: value("body") ?? ""))
    }

    /// The raw original of a message (for invites and anything the reader can't show), in a plain window.
    static func showOriginal(_ message: MailMessage) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = message.subject
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MessageHeader(message: message).padding(.horizontal, 24).padding(.top, 16)
                MessageBodyView(message: message)
            }
        }
        .background(Color(nsColor: Theme.neutral(0))))
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

/// A message being written. Saves itself to Gmail as a draft while it changes.
@MainActor
@Observable
final class ComposeDraft {
    var from: EmailAddress { didSet { changed() } }
    var to: String { didSet { changed() } }
    var cc: String { didSet { changed() } }
    var bcc: String { didSet { changed() } }
    var showsCcBcc: Bool
    var subject: String { didSet { changed() } }
    /// The editor's rich text; plain text and HTML parts are made from it at save and send.
    var body: NSAttributedString { didSet { changed() } }
    var attachments: [MessageBuilder.Attachment] = [] { didSet { changed() } }
    private(set) var state: State = .idle
    let accountID: String
    let threadID: String?
    let inReplyTo: String?
    let references: [String]
    /// The quoted original under a reply or forward, kept apart so the cursor starts above it.
    let quoted: String?
    /// A forward carries the original's attachments along.
    let isForward: Bool

    @ObservationIgnored private var draftID: String?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    enum State: Equatable { case idle, saving, saved(Date), sending, sent, failed(String) }

    init(start: ComposeStart, from: EmailAddress) {
        self.from = from
        var to = "", cc = "", subject = "", quoted: String?, body = ""
        var threadID: String?, inReplyTo: String?, references: [String] = []
        let accountID: String
        switch start {
        case .new(let recipients, let startSubject, let startBody):
            to = recipients.map(\.fieldText).joined(separator: ", ")
            subject = startSubject
            body = startBody
            accountID = AppServices.shared.accountID(owning: from.email) ?? from.email
        case .reply(let message, let all):
            let original = message.headerParsed
            let builder = MessageBuilder.reply(to: original, from: from, all: all, ownAddresses: AppServices.shared.ownAddresses)
            to = builder.to.map(\.fieldText).joined(separator: ", ")
            cc = builder.cc.map(\.fieldText).joined(separator: ", ")
            subject = builder.subject
            inReplyTo = builder.inReplyTo
            references = builder.references
            threadID = message.threadID
            accountID = message.accountID
            quoted = "On \(MailDate.long(message.internalDate)), \(message.from.displayName) wrote:"
        case .forward(let message):
            subject = Reply.forwardSubject(message.subject)
            accountID = message.accountID
            quoted = "---------- Forwarded message ----------\nFrom: \(message.from.fieldText)\nDate: \(MailDate.long(message.internalDate))\nSubject: \(message.subject)"
        }
        self.to = to
        self.cc = cc
        self.bcc = ""
        self.showsCcBcc = !cc.isEmpty
        self.subject = subject
        self.body = NSAttributedString(string: body, attributes: ComposeEditor.typingAttributes)
        self.accountID = accountID
        self.threadID = threadID
        self.inReplyTo = inReplyTo
        self.references = references
        self.quoted = quoted
        if case .forward = start { isForward = true } else { isForward = false }
        if case .reply(let message, _) = start { Task { await self.loadQuote(message) } }
        if case .forward(let message) = start { Task { await self.loadQuote(message) } }
    }

    /// The original's text, quoted with "> " for replies and as-is for forwards.
    @ObservationIgnored private(set) var quotedBody: String = ""
    private func loadQuote(_ message: MailMessage) async {
        let body = try? await AppServices.shared.body(for: message)
        let text = body?.text ?? body?.html.map(NotificationText.stripTags) ?? message.snippet
        quotedBody = !isForward ? text.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n") : text
        if isForward {
            attachmentsToForward = (try? await AppServices.shared.store.attachments(accountID: message.accountID, messageID: message.id)) ?? []
            for attachment in attachmentsToForward {
                if let data = try? await AppServices.shared.attachmentData(attachment) {
                    attachments.append(.init(filename: attachment.filename, mimeType: attachment.mimeType, data: data))
                }
            }
        }
    }

    @ObservationIgnored private var attachmentsToForward: [MailAttachment] = []

    var hasRecipients: Bool { !(AddressParser.parse(to) + AddressParser.parse(cc) + AddressParser.parse(bcc)).isEmpty }

    var isEmpty: Bool {
        to.isEmpty && cc.isEmpty && bcc.isEmpty && subject.isEmpty && body.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }

    func builder() -> MessageBuilder {
        var builder = MessageBuilder(from: from, to: AddressParser.parse(to), cc: AddressParser.parse(cc),
                                     bcc: AddressParser.parse(bcc), subject: subject)
        let (text, html) = ComposeEditor.parts(body, quote: quoted.map { "\($0)\n\(quotedBody)" })
        builder.text = text
        builder.html = html
        builder.inReplyTo = inReplyTo
        builder.references = references
        builder.attachments = attachments
        return builder
    }

    private func changed() {
        guard state != .sending, state != .sent else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    func save() async {
        guard !isEmpty, state != .sending, state != .sent else { return }
        state = .saving
        do {
            draftID = try await AppServices.shared.actions.saveDraft(builder(), accountID: accountID, threadID: threadID, draftID: draftID)
            state = .saved(Date())
        } catch {
            state = .failed("Couldn’t save the draft: \(AppServices.describe(error))")
        }
    }

    func send() async -> Bool {
        guard hasRecipients else {
            state = .failed("Add at least one recipient.")
            return false
        }
        saveTask?.cancel()
        state = .sending
        do {
            try await AppServices.shared.actions.send(builder(), accountID: accountID, threadID: threadID, draftID: draftID)
            state = .sent
            return true
        } catch {
            state = .failed("Couldn’t send: \(AppServices.describe(error)). Your message is still here.")
            return false
        }
    }

    /// Closing an unsent message keeps it as a Gmail draft, unless it is empty.
    func discard() async {
        saveTask?.cancel()
        if let draftID { await AppServices.shared.actions.deleteDraft(draftID, accountID: accountID) }
        self.draftID = nil
    }
}

nonisolated extension MailMessage {
    /// The record's headers as a `ParsedMessage`, for DingoKit's reply helpers.
    var headerParsed: ParsedMessage {
        var fields: [(name: String, value: String)] = [("From", from.fieldText), ("Subject", subject)]
        if !to.isEmpty { fields.append(("To", to.map(\.fieldText).joined(separator: ", "))) }
        if !cc.isEmpty { fields.append(("Cc", cc.map(\.fieldText).joined(separator: ", "))) }
        if let replyTo { fields.append(("Reply-To", replyTo)) }
        if let messageIDHeader { fields.append(("Message-ID", messageIDHeader)) }
        if let inReplyTo { fields.append(("In-Reply-To", inReplyTo)) }
        if let references { fields.append(("References", references)) }
        return ParsedMessage(accountID: accountID, id: id, threadID: threadID, historyID: historyID, labelIDs: labelIDs,
                             internalDate: internalDate, snippet: snippet, headers: .init(fields))
    }
}

nonisolated extension EmailAddress {
    /// How an address reads in a compose field: `Ada Lovelace <ada@example.com>`, quoting names
    /// with commas so the field parses back to the same list.
    var fieldText: String {
        guard let name else { return email }
        let quotedName = name.contains(where: { ",;<>@\"".contains($0) }) ? "\"\(name.replacingOccurrences(of: "\"", with: ""))\"" : name
        return "\(quotedName) <\(email)>"
    }
}
