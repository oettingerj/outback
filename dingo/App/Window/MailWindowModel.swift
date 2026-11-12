import AppKit
import DingoKit
import Eucalyptus
import Observation
import SwiftUI

/// Where the window is: a bucket, or one of Gmail's own mailboxes.
enum Destination: Hashable, Identifiable {
    case bucket(Bucket)
    case mailbox(Mailbox)

    var id: String {
        switch self {
        case .bucket(let bucket): bucket.rawValue
        case .mailbox(let mailbox): mailbox.rawValue
        }
    }

    var title: String {
        switch self {
        case .bucket(let bucket): bucket.title
        case .mailbox(let mailbox): mailbox.title
        }
    }

    var symbol: String {
        switch self {
        case .bucket(let bucket): bucket.symbol
        case .mailbox(let mailbox): mailbox.symbol
        }
    }

    static let rail: [Destination] = [.bucket(.inbox)] + Bucket.sorted.map { .bucket($0) }
}

enum Mailbox: String, CaseIterable, Hashable {
    case starred, sent, drafts

    var title: String {
        switch self {
        case .starred: "Starred"
        case .sent: "Sent"
        case .drafts: "Drafts"
        }
    }

    var symbol: String {
        switch self {
        case .starred: "star"
        case .sent: "paperplane"
        case .drafts: "doc"
        }
    }

    var labelID: String {
        switch self {
        case .starred: "STARRED"
        case .sent: "SENT"
        case .drafts: "DRAFT"
        }
    }
}

/// Which column has the keyboard. j/k move in the focused one.
enum ColumnFocus { case middle, detail }

/// One window's state: where it is, what each column lists, and what is selected. Lists come
/// from database observations, so sync and actions update every window without being told.
@MainActor
@Observable
final class MailWindowModel {
    private(set) var destination: Destination = .bucket(.inbox)
    /// Nil shows every account.
    var accountFilter: Set<String>? { didSet { if accountFilter != oldValue { restartObservations() } } }
    var focus: ColumnFocus = .middle

    private(set) var unreadCounts: [Bucket: Int] = [:]
    private(set) var threads: [ThreadSummary] = []
    private(set) var publications: [Publication] = []
    private(set) var issues: [MailMessage] = []
    private(set) var sources: [NotificationSource] = []
    private(set) var notifications: [MailMessage] = []
    private(set) var months: [ReceiptMonth] = []
    private(set) var receipts: [ReceiptRow] = []
    private(set) var events: [EventRow] = []

    // Selection, per bucket so switching back returns to where you were.
    var selectedThread: ThreadKey?
    var selectedIssue: MessageKey?
    /// Nil is "every publication", newest issue first.
    var newsletterGrouping: NewsletterGrouping = .latest
    var selectedSource: String? { didSet { if selectedSource != oldValue { observeNotifications() } } }
    var selectedNotification: MessageKey?
    var selectedMonth: Date? { didSet { if selectedMonth != oldValue { observeReceipts() } } }
    var selectedReceipt: MessageKey?
    var selectedEvent: MessageKey?

    /// A one-line notice over the detail pane: an undo offer or an error.
    var notice: Notice?

    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var store: MailStore { AppServices.shared.store }

    init() {
        restartObservations()
    }

    func go(to destination: Destination) {
        guard destination != self.destination else { return }
        self.destination = destination
        focus = .middle
        restartListObservation()
    }

    /// Opens a message where it lives, for search results and notifications.
    func reveal(_ message: MailMessage) {
        let key = MessageKey(message)
        let destination: Destination = message.bucket == .inbox && !message.isInInbox
            ? (message.labelIDs.contains("SENT") ? .mailbox(.sent) : .bucket(.inbox)) : .bucket(message.bucket)
        go(to: destination)
        switch message.bucket {
        case .inbox: selectedThread = ThreadKey(accountID: message.accountID, threadID: message.threadID)
        case .newsletters: selectedIssue = key
        case .notifications: selectedSource = nil; selectedNotification = key; focus = .detail
        case .receipts:
            selectedMonth = Calendar.current.dateInterval(of: .month, for: message.internalDate)?.start
            selectedReceipt = key
            focus = .detail
        case .calendar: selectedEvent = key
        }
    }

    // MARK: Observations

    private func restartObservations() {
        observe("counts", store.observeUnreadCounts(accountIDs: accountFilter)) { [weak self] in self?.unreadCounts = $0 }
        restartListObservation()
    }

    private func restartListObservation() {
        for key in ["list", "detail"] { tasks[key]?.cancel() }
        let accounts = accountFilter
        switch destination {
        case .bucket(.inbox):
            observe("list", store.observeThreads(bucket: .inbox, accountIDs: accounts, limit: 500)) { [weak self] in
                self?.threads = $0
                self?.keepThreadSelection()
            }
        case .mailbox(let mailbox):
            observe("list", store.observeThreads(labelID: mailbox.labelID, accountIDs: accounts, limit: 500)) { [weak self] in
                self?.threads = $0
                self?.keepThreadSelection()
            }
        case .bucket(.newsletters):
            observe("list", store.observePublications(accountIDs: accounts)) { [weak self] in self?.publications = $0 }
            observe("detail", store.observeIssues(publication: nil, accountIDs: accounts, limit: 500)) { [weak self] issues in
                guard let self else { return }
                self.issues = issues
                if selectedIssue.map({ key in !issues.contains { MessageKey($0) == key } }) ?? true { selectedIssue = issues.first.map(MessageKey.init) }
            }
        case .bucket(.notifications):
            observe("list", store.observeNotificationSources(accountIDs: accounts)) { [weak self] in
                guard let self else { return }
                sources = $0
                if let selectedSource, !$0.contains(where: { $0.id == selectedSource }) { self.selectedSource = nil }
            }
            observeNotifications()
        case .bucket(.receipts):
            observe("list", store.observeReceiptMonths(accountIDs: accounts)) { [weak self] in
                guard let self else { return }
                months = $0
                if selectedMonth == nil || !$0.contains(where: { $0.month == selectedMonth }) { selectedMonth = $0.first?.month }
            }
            observeReceipts()
        case .bucket(.calendar):
            observe("list", store.observeEvents(accountIDs: accounts)) { [weak self] events in
                guard let self else { return }
                self.events = events
                if selectedEvent.map({ key in !events.contains { MessageKey($0.message) == key } }) ?? true {
                    selectedEvent = (InviteAgenda.upcoming(in: events).first ?? events.first).map { MessageKey($0.message) }
                }
            }
        }
    }

    private func observeNotifications() {
        guard destination == .bucket(.notifications) else { return }
        observe("detail", store.observeNotifications(source: selectedSource, accountIDs: accountFilter, limit: 400)) { [weak self] in
            self?.notifications = $0
        }
    }

    private func observeReceipts() {
        guard destination == .bucket(.receipts) else { return }
        observe("detail", store.observeReceipts(month: selectedMonth, accountIDs: accountFilter)) { [weak self] in
            self?.receipts = $0
        }
    }

    private func observe<T: Sendable>(_ key: String, _ observation: MailObservation<T>, _ apply: @escaping @MainActor (T) -> Void) {
        tasks[key]?.cancel()
        tasks[key] = Task {
            do {
                for try await value in observation {
                    guard !Task.isCancelled else { return }
                    apply(value)
                }
            } catch is CancellationError {
            } catch {
                self.notice = .error("Couldn’t read mail from the local database: \(error.localizedDescription)")
            }
        }
    }

    /// The selection survives refreshes; when its thread disappears (archived elsewhere) the
    /// next thread down takes it, so triage keeps its place.
    private var lastThreadIndex = 0
    private func keepThreadSelection() {
        if let selectedThread, let index = threads.firstIndex(where: { ThreadKey($0) == selectedThread }) {
            lastThreadIndex = index
        } else if !threads.isEmpty, selectedThread != nil {
            selectedThread = ThreadKey(threads[min(lastThreadIndex, threads.count - 1)])
        }
    }

    // MARK: Keyboard movement

    /// Moves the selection in the focused list by `step` rows.
    func move(_ step: Int) {
        switch destination {
        case .bucket(.inbox), .mailbox:
            selectedThread = neighbor(of: selectedThread, in: threads.map(ThreadKey.init), step: step)
        case .bucket(.newsletters):
            selectedIssue = neighbor(of: selectedIssue, in: visibleIssues.map(MessageKey.init), step: step)
        case .bucket(.notifications):
            if focus == .middle {
                let ids: [String?] = [nil] + sources.map(\.id)
                let index = ids.firstIndex(of: selectedSource) ?? 0
                selectedSource = ids[min(max(index + step, 0), ids.count - 1)]
            } else {
                selectedNotification = neighbor(of: selectedNotification, in: notifications.map(MessageKey.init), step: step)
            }
        case .bucket(.receipts):
            if focus == .middle {
                let ids = months.map(\.month)
                let index = selectedMonth.flatMap { ids.firstIndex(of: $0) } ?? 0
                if !ids.isEmpty { selectedMonth = ids[min(max(index + step, 0), ids.count - 1)] }
            } else {
                selectedReceipt = neighbor(of: selectedReceipt, in: receipts.map { MessageKey($0.message) }, step: step)
            }
        case .bucket(.calendar):
            selectedEvent = neighbor(of: selectedEvent, in: InviteAgenda.ordered(events).map { MessageKey($0.message) }, step: step)
        }
    }

    private func neighbor<K: Equatable>(of current: K?, in keys: [K], step: Int) -> K? {
        guard !keys.isEmpty else { return nil }
        guard let current, let index = keys.firstIndex(of: current) else { return keys.first }
        return keys[min(max(index + step, 0), keys.count - 1)]
    }

    /// Issues in the order the middle column shows them.
    var visibleIssues: [MailMessage] {
        switch newsletterGrouping {
        case .latest: issues
        case .publication:
            publications.flatMap { publication in issues.filter { $0.fromEmail == publication.id } }
        }
    }

    // MARK: What the actions apply to

    /// The messages a triage command (archive, read, star, move, trash) acts on now.
    var actionTarget: [MailMessage] {
        switch destination {
        case .bucket(.inbox), .mailbox:
            guard let selectedThread, let thread = threads.first(where: { ThreadKey($0) == selectedThread }) else { return [] }
            return [thread.latest]
        case .bucket(.newsletters):
            return issues.filter { MessageKey($0) == selectedIssue }
        case .bucket(.notifications):
            return notifications.filter { MessageKey($0) == selectedNotification }
        case .bucket(.receipts):
            return receipts.map(\.message).filter { MessageKey($0) == selectedReceipt }
        case .bucket(.calendar):
            return events.map(\.message).filter { MessageKey($0) == selectedEvent }
        }
    }

    /// Whole threads act together in the Inbox and mailboxes; elsewhere each message stands alone.
    var actsOnThreads: Bool {
        switch destination {
        case .bucket(.inbox), .mailbox: true
        default: false
        }
    }
}

enum NewsletterGrouping: String, CaseIterable { case latest, publication }

struct ThreadKey: Hashable {
    let accountID: String
    let threadID: String
    init(accountID: String, threadID: String) {
        self.accountID = accountID
        self.threadID = threadID
    }
    init(_ thread: ThreadSummary) {
        accountID = thread.accountID
        threadID = thread.threadID
    }
}

struct MessageKey: Hashable {
    let accountID: String
    let messageID: String
    init(_ message: MailMessage) {
        accountID = message.accountID
        messageID = message.id
    }
}

enum Notice: Equatable {
    /// An action that can be taken back, such as "Archived 1 conversation".
    case undo(String, id: UUID = UUID())
    /// Offer to remember where a sender's mail goes.
    case rule(sender: EmailAddress, accountID: String, bucket: Bucket, id: UUID = UUID())
    case error(String)
}

/// Splits invites into what's ahead and what's done.
enum InviteAgenda {
    static func upcoming(in events: [EventRow], now: Date = Date()) -> [EventRow] {
        events.filter { ($0.event.end ?? $0.event.start ?? .distantPast) >= now }
            .sorted { ($0.event.start ?? .distantFuture) < ($1.event.start ?? .distantFuture) }
    }

    static func past(in events: [EventRow], now: Date = Date()) -> [EventRow] {
        events.filter { ($0.event.end ?? $0.event.start ?? .distantPast) < now }
            .sorted { ($0.event.start ?? .distantPast) > ($1.event.start ?? .distantPast) }
    }

    static func ordered(_ events: [EventRow]) -> [EventRow] { upcoming(in: events) + past(in: events) }
}
