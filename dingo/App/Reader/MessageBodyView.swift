import AppKit
import DingoKit
import Eucalyptus
import SwiftUI

/// Loads a message's body from the cache, or from Gmail the first time it is opened, and shows it
/// in the reader web view. Remote images wait behind a one-line offer until the sender is trusted.
struct MessageBodyView: View {
    let message: MailMessage
    var measure: CGFloat = 680
    @State private var body_: MailBody?
    @State private var failed: String?
    @State private var height: CGFloat = 120
    @State private var allowsRemote = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let body_ {
                if !allowsRemote, RemoteContent.hasRemoteContent(body_.html) {
                    RemoteContentBar(sender: message.from) {
                        RemoteContent.trust(message.fromEmail)
                        allowsRemote = true
                    } loadOnce: {
                        allowsRemote = true
                    }
                }
                MessageWebView(document: MessageDocument(id: message.id, html: body_.html, text: body_.text ?? message.snippet,
                                                         allowsRemoteContent: allowsRemote, measure: measure),
                               inlinePart: { cid in await AppServices.shared.inlinePart(cid: cid, in: message, body: body_) },
                               height: $height)
                    .frame(height: max(height, 60))
                AttachmentStrip(message: message)
            } else if let failed {
                Text(failed).font(.system(size: 12)).foregroundStyle(Color(nsColor: Theme.fail)).padding(24)
            } else {
                // The snippet stands in while the body arrives, so the reader never flashes empty.
                Text(message.snippet).font(.system(size: 14)).foregroundStyle(pageTertiary)
                    .padding(.horizontal, 24).padding(.vertical, 20)
                    .redacted(reason: .placeholder)
            }
        }
        .task(id: message.id) {
            body_ = nil
            failed = nil
            height = 120
            allowsRemote = RemoteContent.isTrusted(message.fromEmail)
            do {
                body_ = try await AppServices.shared.body(for: message)
                AppServices.shared.markReadOnOpen(message)
            } catch {
                failed = "Couldn’t load this message: \(error.localizedDescription)"
            }
        }
    }
}

/// "Remote images are hidden" with Load Once and Always Load from this sender.
private struct RemoteContentBar: View {
    let sender: EmailAddress
    let always: () -> Void
    let loadOnce: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "eye.slash").font(.system(size: 11)).foregroundStyle(pageTertiary)
            Text("Remote images are hidden so the sender can’t see when you read this.")
                .font(.system(size: 11)).foregroundStyle(pageSecondary).lineLimit(2)
            Spacer(minLength: 8)
            Button("Load Once", action: loadOnce).controlSize(.small)
            Button("Always from \(sender.name ?? sender.email)", action: always).controlSize(.small).lineLimit(1)
        }
        .padding(.horizontal, 24).padding(.vertical, 8)
        .background(Color(nsColor: Theme.neutral(2)))
    }
}

/// Files attached to a message, each opening with Quick Look's app after it downloads.
struct AttachmentStrip: View {
    let message: MailMessage
    @State private var attachments: [MailAttachment] = []

    var body: some View {
        Group {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachment in
                            Button { Task { await AppServices.shared.open(attachment) } } label: {
                                HStack(spacing: 6) {
                                    Image(nsImage: NSWorkspace.shared.icon(for: .init(mimeType: attachment.mimeType) ?? .data))
                                        .resizable().frame(width: 18, height: 18)
                                    Text(attachment.filename).font(.system(size: 12)).foregroundStyle(pagePrimary).lineLimit(1)
                                    FigureText(text: ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                                }
                                .padding(.horizontal, 10).frame(height: 30)
                                .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Color(nsColor: Theme.neutral(2))))
                                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Color(nsColor: Theme.hairline)))
                            }
                            .buttonStyle(.plain)
                            .help("Open \(attachment.filename)")
                        }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 12)
                }
            }
        }
        .task(id: message.id) {
            attachments = (try? await AppServices.shared.store.attachments(accountID: message.accountID, messageID: message.id)) ?? []
        }
    }
}

/// Which senders may load remote content, kept in user defaults by address.
enum RemoteContent {
    private static let key = "TrustedRemoteSenders"

    static func isTrusted(_ email: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(email.lowercased())
    }

    static func trust(_ email: String) {
        var senders = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !senders.contains(email.lowercased()) else { return }
        senders.append(email.lowercased())
        UserDefaults.standard.set(senders, forKey: key)
    }

    static func revoke(_ email: String) {
        UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: key) ?? []).filter { $0 != email.lowercased() }, forKey: key)
    }

    static var trusted: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func hasRemoteContent(_ html: String?) -> Bool {
        guard let html else { return false }
        return html.range(of: #"(src|background|href)\s*=\s*["']?\s*https?://|url\(\s*["']?https?://"#, options: [.regularExpression, .caseInsensitive]) != nil
            && html.range(of: #"(<img|background=|url\()"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
