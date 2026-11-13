import AppKit
import DingoKit
import Eucalyptus
import SwiftUI

/// The detail pane shows the selection in its bucket's own form.
struct DetailPane: View {
    @Bindable var model: MailWindowModel

    var body: some View {
        VStack(spacing: 0) {
            if let notice = model.notice { NoticeBar(notice: notice, model: model) }
            Group {
                if AppServices.shared.accounts.isEmpty {
                    WelcomeView()
                } else {
                    switch model.destination {
                    case .bucket(.inbox), .mailbox: ConversationDetail(model: model)
                    case .bucket(.newsletters): IssueDetail(model: model)
                    case .bucket(.notifications): NotificationLog(model: model)
                    case .bucket(.receipts): ReceiptLedger(model: model)
                    case .bucket(.calendar): InviteDetail(model: model)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Color(nsColor: Theme.neutral(0)))
        .simultaneousGesture(TapGesture().onEnded { if model.destination.hasDetailList { model.focus = .detail } })
    }
}

extension Destination {
    /// Buckets whose detail pane is itself a list j/k can walk.
    var hasDetailList: Bool { self == .bucket(.notifications) || self == .bucket(.receipts) }
}

/// Nothing selected: a quiet line, never a blank pane.
private struct NoSelection: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 13)).foregroundStyle(pageTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A message's sender line: name, address in mono, time, and who else it went to.
struct MessageHeader: View {
    let message: MailMessage
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(message.from.displayName).font(.system(size: 13, weight: .semibold)).foregroundStyle(pagePrimary)
                if message.from.name != nil {
                    Text(message.fromEmail).font(.mono(size: 11)).foregroundStyle(pageTertiary).textSelection(.enabled)
                }
                Spacer(minLength: 8)
                FigureText(text: MailDate.long(message.internalDate))
            }
            let recipients = (message.to + message.cc).map { AppServices.shared.isMine($0.email) ? "me" : $0.displayName }
            if !recipients.isEmpty {
                Text("to \(recipients.joined(separator: ", "))").font(.system(size: 12)).foregroundStyle(pageSecondary).lineLimit(1)
            }
        }
    }
}

// MARK: Conversation

private struct ConversationDetail: View {
    @Bindable var model: MailWindowModel
    @State private var messages: [MailMessage] = []
    @State private var expanded: Set<String> = []

    var body: some View {
        if let key = model.selectedThread {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(messages.last?.subject.nonEmpty ?? "(no subject)")
                        .font(.system(size: 20, weight: .semibold)).foregroundStyle(pagePrimary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 14)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(messages, id: \.id) { message in
                        SettingsRule()
                        if expanded.contains(message.id) || message.id == messages.last?.id {
                            MessageHeader(message: message).padding(.horizontal, 24).padding(.top, 16)
                            MessageBodyView(message: message, measure: 720)
                        } else {
                            Button { expanded.insert(message.id) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(message.from.displayName).font(.system(size: 13, weight: message.isUnread ? .semibold : .medium)).foregroundStyle(pagePrimary)
                                    Text(message.snippet).font(.system(size: 12)).foregroundStyle(pageTertiary).lineLimit(1)
                                    Spacer(minLength: 8)
                                    FigureText(text: MailDate.short(message.internalDate))
                                }
                                .padding(.horizontal, 24).frame(height: 40).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Spacer(minLength: 32)
                }
                .frame(maxWidth: 820, alignment: .leading)
            }
            .task(id: key) {
                expanded = []
                messages = (try? await AppServices.shared.store.thread(accountID: key.accountID, threadID: key.threadID)) ?? []
                // Unread messages open expanded, like reading a stack of letters you haven't seen.
                expanded = Set(messages.filter(\.isUnread).map(\.id))
            }
        } else {
            NoSelection(text: model.threads.isEmpty ? "" : "Select a conversation, or press J.")
        }
    }
}

// MARK: Newsletters

private struct IssueDetail: View {
    @Bindable var model: MailWindowModel

    var body: some View {
        if let key = model.selectedIssue, let issue = model.issues.first(where: { MessageKey($0) == key }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(issue.subject.nonEmpty ?? "(untitled issue)").font(.system(size: 24, weight: .semibold)).foregroundStyle(pagePrimary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(issue.from.displayName).font(.system(size: 12, weight: .semibold)).foregroundStyle(pagePrimary)
                            FigureText(text: MailDate.long(issue.internalDate))
                            PublicationActions(issue: issue)
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 18)
                    MessageBodyView(message: issue, measure: 680)
                        .frame(maxWidth: 744)
                        .padding(.bottom, 32)
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            NoSelection(text: "Pick an issue to read.")
        }
    }
}

/// Unsubscribe and Mute for the issue's publication.
private struct PublicationActions: View {
    let issue: MailMessage
    @State private var state: String?

    var body: some View {
        HStack(spacing: 4) {
            if let state {
                Text(state).font(.system(size: 11)).foregroundStyle(pageTertiary)
            } else {
                if Unsubscribe.target(for: issue) != nil {
                    TextButton("Unsubscribe") { Task { state = await Unsubscribe.perform(issue) } }
                }
                Text("·").foregroundStyle(pageTertiary).font(.system(size: 11)).accessibilityHidden(true)
                TextButton("Always Put in Notifications") {
                    Task { await AppServices.shared.actions.move([issue], to: .notifications, rememberSender: true) }
                }
            }
        }
    }
}

// MARK: Notifications

private struct NotificationLog: View {
    @Bindable var model: MailWindowModel

    var body: some View {
        if model.notifications.isEmpty {
            NoSelection(text: "Nothing from this source.")
        } else {
            VStack(spacing: 0) {
                HStack {
                    let source = model.sources.first { $0.id == model.selectedSource }
                    Text(source?.title ?? "All Sources")
                        .font(source?.kind == .github ? .mono(size: 12, weight: .bold) : .system(size: 13, weight: .semibold))
                        .foregroundStyle(pagePrimary)
                    FigureText(text: "\(model.notifications.count)")
                    Spacer()
                    Button("Mark All Read") { Task { await AppServices.shared.actions.setUnread(model.notifications.filter(\.isUnread), false) } }
                        .disabled(!model.notifications.contains(where: \.isUnread))
                    Button("Archive Read") { Task { await AppServices.shared.actions.archive(model.notifications.filter { !$0.isUnread }, wholeThread: false) } }
                        .disabled(!model.notifications.contains { !$0.isUnread })
                    Button("Delete Read") { Task { await AppServices.shared.actions.trash(model.notifications.filter { !$0.isUnread }, wholeThread: false) } }
                        .disabled(!model.notifications.contains { !$0.isUnread })
                }
                .controlSize(.small)
                .padding(.horizontal, 18).padding(.vertical, 10)
                SettingsRule()
                SelectableList(selection: model.selectedNotification) {
                    ForEach(model.notifications, id: \.id) { note in
                        let key = MessageKey(note)
                        let isSelected = model.selectedNotification == key
                        VStack(alignment: .leading, spacing: 0) {
                            ListRow(isUnread: note.isUnread, title: NotificationText.title(note), subtitle: NotificationText.summary(note),
                                    isSelected: isSelected, isFocused: model.focus == .detail) {
                                HStack(spacing: 8) {
                                    CIStateMark(state: NotificationText.ciState(note))
                                    FigureText(text: MailDate.short(note.internalDate))
                                }
                            }
                            if isSelected { NotificationExpansion(message: note) }
                        }
                        .id(key)
                        .onTapGesture { model.selectedNotification = key; model.focus = .detail }
                        .contextMenu { MessageContextMenu(messages: [note], wholeThread: false) }
                    }
                }
            }
        }
    }
}

/// The selected notification: its text, and a button to the page it is about. The text is a
/// stripped gist that keeps the log dense; Show Full Message renders the original on request,
/// for senders whose mail only makes sense as HTML.
private struct NotificationExpansion: View {
    let message: MailMessage
    @State private var text: String?
    @State private var link: URL?
    @State private var showsFull = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsFull {
                // The body view insets its own 24pt; pulling it out by that much lines its panel up with the text.
                MessageBodyView(message: message, measure: 680).padding(.leading, -24).padding(.trailing, -18)
            } else if let text, !text.isEmpty, text != NotificationText.summary(message) {
                Text(text).font(.system(size: 12)).foregroundStyle(pageSecondary).lineLimit(12).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                if let link {
                    Button("Open \(link.host() ?? "Link")") { NSWorkspace.shared.open(link) }.buttonStyle(SettingsPrimaryButtonStyle())
                }
                Button("Archive") { Task { await AppServices.shared.actions.archive([message], wholeThread: false) } }.controlSize(.small)
                Button("Delete") { Task { await AppServices.shared.actions.trash([message], wholeThread: false) } }.controlSize(.small)
                Button(showsFull ? "Hide Full Message" : "Show Full Message") { showsFull.toggle() }.controlSize(.small)
            }
        }
        .padding(.leading, 34).padding(.trailing, 18).padding(.vertical, 10)
        .task(id: message.id) {
            let body = try? await AppServices.shared.body(for: message)
            text = NotificationText.plain(body, fallback: message.snippet)
            link = NotificationText.primaryLink(body)
            AppServices.shared.markReadOnOpen(message)
        }
    }
}

/// A CI run's outcome in the state colors, beside the time.
struct CIStateMark: View {
    let state: NotificationText.CIState?
    var body: some View {
        switch state {
        case .failed?: StateWord(text: "Failed", color: Color(nsColor: Theme.fail), symbol: "xmark.circle.fill")
        case .passed?: StateWord(text: "Passed", color: Color(nsColor: Theme.pass), symbol: "checkmark.circle.fill")
        case .running?: StateWord(text: "Running", color: Color(nsColor: Theme.pending), symbol: "circle.dotted")
        case nil: EmptyView()
        }
    }
}

enum NotificationText {
    enum CIState { case failed, passed, running }

    /// CI outcome from the subject line GitHub, Vercel, and most CI services send.
    static func ciState(_ message: MailMessage) -> CIState? {
        let subject = message.subject.lowercased()
        if subject.range(of: #"\b(run failed|failed|failing|failure|errored|broken)\b"#, options: .regularExpression) != nil { return .failed }
        if subject.range(of: #"\b(run (succeeded|passed)|succeeded|passed|fixed|deploy(ment)? (succeeded|ready))\b"#, options: .regularExpression) != nil { return .passed }
        if subject.range(of: #"\b(in progress|queued|running)\b"#, options: .regularExpression) != nil { return .running }
        return nil
    }

    /// The subject without the "[owner/repo]" prefix the source column already shows.
    static func title(_ message: MailMessage) -> String {
        message.subject.replacingOccurrences(of: #"^(Re: )?\[[^\]]+\]\s*"#, with: "$1", options: .regularExpression)
    }

    /// The snippet minus GitHub's "@user commented on this pull request" boilerplate tail.
    static func summary(_ message: MailMessage) -> String {
        message.snippet.replacingOccurrences(of: #"\s*—\s*Reply to this email directly.*$"#, with: "", options: .regularExpression)
    }

    static func plain(_ body: MailBody?, fallback: String) -> String {
        let text = body?.text ?? body?.html.map(BodyText.plain(fromHTML:)) ?? fallback
        // Text parts carry the sender's indentation and whitespace-only spacer lines; trim each
        // line so blank runs collapse and nothing sits indented.
        return text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.hasPrefix("http") }.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .components(separatedBy: "\n—\nReply to this email directly").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fallback
    }

    /// The first link that looks like the thing itself (a PR, issue, run, or deploy), skipping
    /// unsubscribe and settings links.
    static func primaryLink(_ body: MailBody?) -> URL? {
        let haystack = (body?.text ?? "") + " " + (body?.html ?? "")
        let pattern = #"https://[^\s"'<>)]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(haystack.startIndex..., in: haystack)
        for match in regex.matches(in: haystack, range: range) {
            guard let r = Range(match.range, in: haystack) else { continue }
            let string = String(haystack[r]).replacingOccurrences(of: "&amp;", with: "&")
            if string.range(of: #"unsubscribe|notifications/|settings|beacon|track|\.(png|gif|jpg)"#, options: [.regularExpression, .caseInsensitive]) != nil { continue }
            if let url = URL(string: string) { return url }
        }
        return nil
    }
}

// MARK: Receipts

private struct ReceiptLedger: View {
    @Bindable var model: MailWindowModel

    var body: some View {
        if model.receipts.isEmpty {
            NoSelection(text: "No receipts this month.")
        } else {
            GeometryReader { geometry in
                // The ledger is as tall as its rows (up to half the pane, then it scrolls); the
                // totals sit right under it, and the selected receipt fills what remains.
                let ledger = min(CGFloat(model.receipts.count) * 37 + 12, geometry.size.height * 0.5)
                VStack(spacing: 0) {
                    LedgerHeader()
                    SettingsRule()
                    SelectableList(selection: model.selectedReceipt) {
                        ForEach(model.receipts, id: \.message.id) { row in
                            let key = MessageKey(row.message)
                            LedgerRow(row: row, isSelected: model.selectedReceipt == key, isFocused: model.focus == .detail)
                                .id(key)
                                .onTapGesture { model.selectedReceipt = key; model.focus = .detail }
                                .contextMenu { MessageContextMenu(messages: [row.message], wholeThread: false) }
                        }
                    }
                    .frame(height: ledger)
                    SettingsRule()
                    LedgerTotals(month: model.months.first { $0.month == model.selectedMonth })
                    SettingsRule()
                    if let key = model.selectedReceipt, let row = model.receipts.first(where: { MessageKey($0.message) == key }) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                MessageHeader(message: row.message).padding(.horizontal, 24).padding(.top, 16)
                                MessageBodyView(message: row.message, measure: 680).padding(.bottom, 24)
                            }
                        }
                    } else {
                        NoSelection(text: "Select a receipt to see the original.")
                    }
                }
            }
        }
    }
}

private enum LedgerColumns {
    static let date: CGFloat = 64
    static let order: CGFloat = 150
    static let status: CGFloat = 84
    static let amount: CGFloat = 110
}

private struct LedgerHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Date").frame(width: LedgerColumns.date, alignment: .leading)
            Text("Merchant").frame(maxWidth: .infinity, alignment: .leading)
            Text("Order").frame(width: LedgerColumns.order, alignment: .leading)
            Text("Status").frame(width: LedgerColumns.status, alignment: .leading)
            Text("Amount").frame(width: LedgerColumns.amount, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .semibold)).foregroundStyle(pageSecondary)
        .padding(.horizontal, 18).frame(height: 32)
    }
}

private struct LedgerRow: View {
    let row: ReceiptRow
    let isSelected: Bool
    let isFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            FigureText(text: row.receipt.date.formatted(.dateTime.day().month(.abbreviated))).frame(width: LedgerColumns.date, alignment: .leading)
            Text(row.receipt.merchant ?? row.message.from.displayName).font(.system(size: 13)).foregroundStyle(pagePrimary)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            FigureText(text: row.receipt.orderNumber ?? "—").frame(width: LedgerColumns.order, alignment: .leading)
            StatusText(status: row.receipt.status).frame(width: LedgerColumns.status, alignment: .leading)
            FigureText(text: Money.format(row.receipt.amount, currency: row.receipt.currency), color: pagePrimary)
                .frame(width: LedgerColumns.amount, alignment: .trailing)
        }
        .padding(.horizontal, 12).frame(height: 36)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Color(nsColor: isSelected ? RowFill.selected : .clear)))
        .overlay { if isSelected && isFocused { RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(pageAccent, lineWidth: 1.5) } }
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct StatusText: View {
    let status: ReceiptStatus
    var body: some View {
        let (text, color): (String, Color?) = switch status {
        case .ordered: ("Ordered", nil)
        case .shipped: ("Shipped", Color(nsColor: Theme.pending))
        case .delivered: ("Delivered", Color(nsColor: Theme.pass))
        case .refunded: ("Refunded", Color(nsColor: Theme.merged))
        case .paid: ("Paid", nil)
        default: ("—", nil)
        }
        if let color { StateWord(text: text, color: color) } else { Text(text).font(.system(size: 12)).foregroundStyle(pageSecondary) }
    }
}

private struct LedgerTotals: View {
    let month: ReceiptMonth?
    var body: some View {
        HStack {
            Text(month.map { "\($0.count) receipts in \($0.month.formatted(.dateTime.month(.wide).year()))" } ?? "")
                .font(.system(size: 12)).foregroundStyle(pageSecondary)
            Spacer()
            ForEach((month?.totals ?? [:]).sorted { $0.key < $1.key }, id: \.key) { currency, total in
                Text(Money.format(total, currency: currency)).font(.mono(size: 13, weight: .bold)).foregroundStyle(pagePrimary)
            }
        }
        .padding(.horizontal, 24).frame(height: 40)
    }
}

// MARK: Invites

private struct InviteDetail: View {
    @Bindable var model: MailWindowModel

    var body: some View {
        if let key = model.selectedEvent, let row = model.events.first(where: { MessageKey($0.message) == key }) {
            let event = row.event
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(event.summary ?? row.message.subject).font(.system(size: 22, weight: .semibold)).foregroundStyle(pagePrimary)
                            .strikethrough(event.isCanceled).textSelection(.enabled)
                            .accessibilityAddTraits(.isHeader)
                        Text(EventFormat.when(event, compact: false)).font(.mono(size: 13)).foregroundStyle(pagePrimary)
                        if let zone = event.timeZone, zone != TimeZone.current.identifier {
                            Text("Organizer’s time zone: \(zone)").font(.system(size: 11)).foregroundStyle(pageTertiary)
                        }
                    }
                    if event.isCanceled {
                        Text("\(event.organizerName ?? "The organizer") canceled this event.").font(.system(size: 13)).foregroundStyle(Color(nsColor: Theme.fail))
                    } else if event.method == .request {
                        RSVPBar(row: row)
                    }
                    PreviewFactGrid(facts: facts(event)).tint(pageAccentText)
                    if !event.attendees.isEmpty { AttendeeList(attendees: event.attendees) }
                    if let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                        Text(notes).font(.system(size: 12)).foregroundStyle(pageSecondary).textSelection(.enabled)
                    }
                    HStack(spacing: 8) {
                        Button("Open in Calendar") { Task { await AppServices.shared.openInCalendar(row.message) } }
                        Button("Show Original Message") { Compose.showOriginal(row.message) }
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 32).padding(.vertical, 28)
                .frame(maxWidth: 680, alignment: .leading)
            }
        } else {
            NoSelection(text: "Pick an invitation.")
        }
    }

    private func facts(_ event: CalendarEvent) -> [PreviewFact] {
        var facts: [PreviewFact] = []
        if let location = event.location, !location.isEmpty {
            if let url = URL(string: location), url.scheme?.hasPrefix("http") == true {
                facts.append(PreviewFact(label: "Where", value: Text(.init("[\(url.host() ?? location)](\(location))"))))
            } else {
                facts.append(PreviewFact(label: "Where", value: Text(location)))
            }
        }
        if let organizer = event.organizerEmail {
            facts.append(PreviewFact(label: "Organizer", value: Text(event.organizerName.map { "\($0) <\(organizer)>" } ?? organizer)))
        }
        if let link = event.url, let url = URL(string: link) {
            facts.append(PreviewFact(label: "Link", value: Text(.init("[\(url.host() ?? link)](\(link))"))))
        }
        return facts
    }
}

/// Going (filled, the primary action), Maybe, Not Going. The answer goes to the organizer as an
/// iMIP reply from the invited account.
private struct RSVPBar: View {
    let row: EventRow
    @State private var sending: ParticipationStatus?

    var body: some View {
        HStack(spacing: 8) {
            Text("Going?").font(.system(size: 13, weight: .medium)).foregroundStyle(pagePrimary)
            choice("Yes", .accepted, primary: true)
            choice("Maybe", .tentative, primary: false)
            choice("No", .declined, primary: false)
            if sending != nil { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder
    private func choice(_ title: String, _ status: ParticipationStatus, primary: Bool) -> some View {
        let chosen = row.event.myResponse == status
        let button = Button {
            sending = status
            Task {
                await AppServices.shared.actions.respond(to: row, with: status)
                sending = nil
            }
        } label: {
            if chosen { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
        .disabled(sending != nil)
        if primary && row.event.myResponse == nil {
            button.buttonStyle(SettingsPrimaryButtonStyle())
        } else {
            button.controlSize(.regular)
        }
    }
}

private struct AttendeeList: View {
    let attendees: [CalendarAttendee]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(attendees.count) invited").font(.system(size: 11, weight: .semibold)).foregroundStyle(pageSecondary)
            ForEach(attendees.prefix(30), id: \.email) { attendee in
                HStack(spacing: 8) {
                    Circle().fill(color(attendee.status)).frame(width: 7, height: 7).accessibilityHidden(true)
                    Text(attendee.name ?? attendee.email).font(.system(size: 12)).foregroundStyle(pagePrimary)
                    if attendee.name != nil { Text(attendee.email).font(.mono(size: 11)).foregroundStyle(pageTertiary) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(label(attendee.status))
            }
            if attendees.count > 30 { Text("and \(attendees.count - 30) more").font(.system(size: 11)).foregroundStyle(pageTertiary) }
        }
    }

    private func color(_ status: ParticipationStatus) -> Color {
        switch status {
        case .accepted: Color(nsColor: Theme.pass)
        case .tentative: Color(nsColor: Theme.pending)
        case .declined: Color(nsColor: Theme.fail)
        default: Color(nsColor: Theme.neutral(5))
        }
    }

    private func label(_ status: ParticipationStatus) -> String {
        switch status {
        case .accepted: "going"
        case .tentative: "maybe"
        case .declined: "not going"
        default: "no answer"
        }
    }
}

// MARK: Notices and welcome

private struct NoticeBar: View {
    let notice: Notice
    let model: MailWindowModel

    var body: some View {
        HStack(spacing: 10) {
            switch notice {
            case .undo(let text, _):
                Text(text).font(.system(size: 12)).foregroundStyle(pagePrimary)
                Spacer()
                Button("Undo") { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil); model.notice = nil }.controlSize(.small)
            case .rule(let sender, let accountID, let bucket, _):
                Text("Always put mail from \(sender.name ?? sender.email) in \(bucket.title)?").font(.system(size: 12)).foregroundStyle(pagePrimary)
                Spacer()
                Button("Always") {
                    Task { await AppServices.shared.actions.remember(sender: sender, accountID: accountID, bucket: bucket); model.notice = nil }
                }
                .buttonStyle(SettingsPrimaryButtonStyle())
                Button("Just This") { model.notice = nil }.controlSize(.small)
                Button("Undo") { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil); model.notice = nil }.controlSize(.small)
            case .error(let text):
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Color(nsColor: Theme.fail))
                Text(text).font(.system(size: 12)).foregroundStyle(pagePrimary).lineLimit(2)
                Spacer()
            }
            Button { model.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(pageTertiary).help("Dismiss").accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 18).frame(minHeight: 40)
        .background(Color(nsColor: Theme.neutral(2)))
        .overlay(alignment: .bottom) { SettingsRule() }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// No account yet: say what Dingo does and offer the one action.
private struct WelcomeView: View {
    @State private var isSigningIn = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add your Gmail account").font(.system(size: 22, weight: .semibold)).foregroundStyle(pagePrimary)
            Text("Dingo keeps the inbox for mail from people. Newsletters, notifications, receipts, and invites each get their own bucket, mirrored to Gmail as Dingo labels so the web and your phone agree.")
                .font(.system(size: 13)).foregroundStyle(pageSecondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(isSigningIn ? "Waiting for Google…" : "Sign In with Google…") {
                    isSigningIn = true
                    error = nil
                    Task {
                        do { try await AppServices.shared.addAccount() } catch { self.error = AppServices.describe(error) }
                        isSigningIn = false
                    }
                }
                .buttonStyle(SettingsPrimaryButtonStyle())
                .disabled(isSigningIn)
                if isSigningIn {
                    Button("Cancel") { AppServices.shared.cancelSignIn() }.controlSize(.small)
                }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color(nsColor: Theme.fail)).fixedSize(horizontal: false, vertical: true) }
            Text("Sign-in opens in your browser. Dingo asks Gmail for permission to read, label, and send mail; it never deletes mail permanently.")
                .font(.system(size: 11)).foregroundStyle(pageTertiary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 460, alignment: .leading)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// An inline text action in the accent's text color, underlined on hover.
struct TextButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(pageAccentText).underline(isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
