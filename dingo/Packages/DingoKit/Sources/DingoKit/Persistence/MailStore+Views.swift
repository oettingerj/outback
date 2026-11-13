import Foundation
import GRDB

/// A conversation as a list row: its newest message, how many there are, and who wrote.
public struct ThreadSummary: Sendable, Equatable, Identifiable {
    public var accountID: String
    public var threadID: String
    public var latest: MailMessage
    public var messageCount: Int
    /// True when any message in the thread is unread, starred, or has attachments.
    public var hasUnread: Bool
    public var isStarred: Bool
    public var hasAttachments: Bool
    /// Senders in the order they first wrote, each once.
    public var participants: [EmailAddress]

    public var id: String { accountID + "/" + threadID }
    public var date: Date { latest.internalDate }
}

/// One newsletter: every issue from one sender address.
public struct Publication: Sendable, Equatable, Identifiable {
    /// The sender address.
    public var id: String
    public var name: String
    public var latestDate: Date
    public var unreadCount: Int
    public var issueCount: Int
    public var latestIssue: MailMessage
    /// From the latest issue, for one-click unsubscribe (RFC 8058).
    public var listUnsubscribe: String?
    public var listUnsubscribePost: String?
}

/// Where notifications come from: a GitHub repository, else the sender's domain.
public struct NotificationSource: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable { case github, other }

    /// "owner/repo" or a domain; the `source` column of its messages.
    public var id: String
    /// The repository, or the latest sender's name.
    public var title: String
    public var kind: Kind
    public var count: Int
    public var unreadCount: Int
    public var latestDate: Date

    /// GitHub's List-Id is `owner/repo <repo.owner.github.com>`. Owners cannot contain dots, so the
    /// address form splits at the last one when the display part is missing.
    static func key(listID: String?, fromDomain: String) -> String {
        guard let listID = listID?.lowercased(), listID.contains(".github.com") else { return fromDomain }
        if let lt = listID.firstIndex(of: "<") {
            let display = listID[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            if display.split(separator: "/").count == 2 { return display }
        }
        let address = listID.trimmingCharacters(in: CharacterSet(charactersIn: " <>\""))
            .split(separator: "<").last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " <>")) } ?? ""
        guard address.hasSuffix(".github.com") else { return fromDomain }
        let name = address.dropLast(".github.com".count)
        guard let dot = name.lastIndex(of: ".") else { return fromDomain }
        return name[name.index(after: dot)...] + "/" + name[..<dot]
    }
}

/// A calendar month of receipts, with what was spent in each currency.
public struct ReceiptMonth: Sendable, Equatable, Identifiable {
    /// The first moment of the month.
    public var month: Date
    public var count: Int
    public var totals: [String: Decimal]

    public var id: Date { month }
}

public struct ReceiptRow: Sendable, Equatable, Identifiable {
    public var receipt: Receipt
    public var message: MailMessage
    public var id: String { receipt.id }
}

public struct EventRow: Sendable, Equatable, Identifiable {
    public var event: CalendarEvent
    public var message: MailMessage
    public var id: String { event.id }
}

/// Queries behind each view. Each is a `Database` function, so `observe…` and `read(_:)` share it.
/// A nil `accountIDs` means every account, for the unified views. Trash and spam never appear,
/// and bucket views show only filed mail (`MailMessage.isFiled`); label views ignore filing.
extension MailStore {
    // MARK: - Unread counts

    public func observeUnreadCounts(accountIDs: Set<String>? = nil) -> AsyncValueObservation<[Bucket: Int]> {
        observe { db in try Self.unreadCounts(db, accountIDs: accountIDs) }
    }

    /// Unread threads per bucket, every bucket present (zero when none). The inbox counts only
    /// threads still in INBOX; sorted buckets only filed mail.
    public static func unreadCounts(_ db: Database, accountIDs: Set<String>?) throws -> [Bucket: Int] {
        var counts = Dictionary(uniqueKeysWithValues: Bucket.allCases.map { ($0, 0) })
        let rows = try SQLRequest<Row>(literal: """
            SELECT bucket, COUNT(DISTINCT accountID || char(31) || threadID) AS count FROM message
            WHERE isUnread AND NOT isTrashOrSpam AND (CASE WHEN bucket = 'inbox' THEN isInInbox ELSE isFiled END) \(accountScope(accountIDs))
            GROUP BY bucket
            """).fetchAll(db)
        for row in rows {
            if let bucket = Bucket(rawValue: row["bucket"]) { counts[bucket] = row["count"] }
        }
        return counts
    }

    // MARK: - Threads

    /// Threads with a message in `bucket`, newest first. The inbox shows only threads still in INBOX;
    /// sorted buckets show everything in them, since bucketing archives.
    public func observeThreads(bucket: Bucket, accountIDs: Set<String>? = nil, limit: Int = 100) -> AsyncValueObservation<[ThreadSummary]> {
        observe { db in try Self.threads(db, bucket: bucket, accountIDs: accountIDs, limit: limit) }
    }

    /// Threads with a message carrying a Gmail label (STARRED, SENT, DRAFT), whatever their bucket.
    public func observeThreads(labelID: String, accountIDs: Set<String>? = nil, limit: Int = 100) -> AsyncValueObservation<[ThreadSummary]> {
        observe { db in try Self.threads(db, labelID: labelID, accountIDs: accountIDs, limit: limit) }
    }

    public static func threads(_ db: Database, bucket: Bucket, accountIDs: Set<String>?, limit: Int, before: Date? = nil) throws -> [ThreadSummary] {
        try threads(db, membership: bucketFilter(bucket), accountIDs: accountIDs, limit: limit, before: before)
    }

    public static func threads(_ db: Database, labelID: String, accountIDs: Set<String>?, limit: Int, before: Date? = nil) throws -> [ThreadSummary] {
        let membership: SQL = """
            EXISTS (SELECT 1 FROM json_each(message.labelIDsJSON) WHERE json_each.value = \(labelID)) AND NOT message.isTrashOrSpam
            """
        return try threads(db, membership: membership, accountIDs: accountIDs, limit: limit, before: before)
    }

    /// Threads with a message matching `membership`. Counts, flags, and participants cover the whole
    /// thread, so a reply the user sent shows with the newsletter it answers. `before` pages by the
    /// last summary's `date`; threads with exactly that date can be skipped.
    static func threads(_ db: Database, membership: SQL, accountIDs: Set<String>?, limit: Int, before: Date?) throws -> [ThreadSummary] {
        let scope = accountScope(accountIDs)
        let beforeClause: SQL = before.map { "AND internalDate < \($0)" } ?? ""
        let rows = try SQLRequest<Row>(literal: """
            SELECT * FROM (
                SELECT message.*,
                    ROW_NUMBER() OVER (PARTITION BY accountID, threadID ORDER BY internalDate DESC) AS rowNumber,
                    COUNT(*) OVER thread AS threadCount,
                    MAX(isUnread) OVER thread AS anyUnread,
                    MAX(isStarred) OVER thread AS anyStarred,
                    MAX(hasAttachments) OVER thread AS anyAttachments
                FROM message
                WHERE NOT isTrashOrSpam \(scope)
                  AND (accountID, threadID) IN (SELECT accountID, threadID FROM message WHERE \(membership) \(scope))
                WINDOW thread AS (PARTITION BY accountID, threadID)
            )
            WHERE rowNumber = 1 \(beforeClause)
            ORDER BY internalDate DESC
            LIMIT \(limit)
            """).fetchAll(db)
        var summaries = try rows.map { row in
            let latest = try MailMessage(row: row)
            return ThreadSummary(accountID: latest.accountID, threadID: latest.threadID, latest: latest,
                                 messageCount: row["threadCount"], hasUnread: row["anyUnread"], isStarred: row["anyStarred"],
                                 hasAttachments: row["anyAttachments"], participants: [])
        }
        guard !summaries.isEmpty else { return [] }

        let threadIDs = Array(Set(summaries.map(\.threadID)))
        let senders = try SQLRequest<Row>(literal: """
            SELECT accountID, threadID, fromName, fromEmail FROM message
            WHERE threadID IN \(threadIDs) AND NOT isTrashOrSpam \(scope)
            ORDER BY internalDate
            """).fetchAll(db)
        var participants: [String: [EmailAddress]] = [:]
        for row in senders {
            let key = (row["accountID"] as String) + "/" + (row["threadID"] as String)
            let address = EmailAddress(name: row["fromName"], email: row["fromEmail"])
            if participants[key]?.contains(where: { $0.email == address.email }) != true {
                participants[key, default: []].append(address)
            }
        }
        for index in summaries.indices { summaries[index].participants = participants[summaries[index].id] ?? [] }
        return summaries
    }

    // MARK: - Newsletters

    public func observePublications(accountIDs: Set<String>? = nil) -> AsyncValueObservation<[Publication]> {
        observe { db in try Self.publications(db, accountIDs: accountIDs) }
    }

    /// Issues newest first: one publication's, or every newsletter's when `publication` is nil.
    public func observeIssues(publication: String?, accountIDs: Set<String>? = nil, limit: Int = 100) -> AsyncValueObservation<[MailMessage]> {
        observe { db in
            try Self.messages(db, bucket: .newsletters, column: "fromEmail", value: publication?.lowercased(), accountIDs: accountIDs, limit: limit)
        }
    }

    /// One row per sender address in Newsletters, most recent issue first.
    public static func publications(_ db: Database, accountIDs: Set<String>?) throws -> [Publication] {
        try latestPerGroup(db, bucket: .newsletters, column: "fromEmail", accountIDs: accountIDs).map { group in
            Publication(id: group.latest.fromEmail, name: group.latest.fromName ?? group.latest.fromEmail,
                        latestDate: group.latest.internalDate, unreadCount: group.unread, issueCount: group.count,
                        latestIssue: group.latest, listUnsubscribe: group.latest.listUnsubscribe,
                        listUnsubscribePost: group.latest.listUnsubscribePost)
        }
    }

    // MARK: - Notifications

    public func observeNotificationSources(accountIDs: Set<String>? = nil) -> AsyncValueObservation<[NotificationSource]> {
        observe { db in try Self.notificationSources(db, accountIDs: accountIDs) }
    }

    /// Notifications newest first: one source's, or all when `source` is nil.
    public func observeNotifications(source: String?, accountIDs: Set<String>? = nil, limit: Int = 100) -> AsyncValueObservation<[MailMessage]> {
        observe { db in
            try Self.messages(db, bucket: .notifications, column: "source", value: source, accountIDs: accountIDs, limit: limit)
        }
    }

    /// One row per source in Notifications, most recent first.
    public static func notificationSources(_ db: Database, accountIDs: Set<String>?) throws -> [NotificationSource] {
        try latestPerGroup(db, bucket: .notifications, column: "source", accountIDs: accountIDs).map { group in
            let source = group.latest.source
            let isGitHub = source.contains("/")
            return NotificationSource(id: source, title: isGitHub ? source : group.latest.fromName ?? source,
                                      kind: isGitHub ? .github : .other, count: group.count, unreadCount: group.unread,
                                      latestDate: group.latest.internalDate)
        }
    }

    // MARK: - Receipts

    /// Months with receipts, newest first, grouped in `calendar`.
    public func observeReceiptMonths(accountIDs: Set<String>? = nil, calendar: Calendar = .current) -> AsyncValueObservation<[ReceiptMonth]> {
        observe { db in try Self.receiptMonths(db, accountIDs: accountIDs, calendar: calendar) }
    }

    /// Receipts newest first: one month's (`month` is any date in it), or all when nil.
    public func observeReceipts(month: Date?, accountIDs: Set<String>? = nil, calendar: Calendar = .current) -> AsyncValueObservation<[ReceiptRow]> {
        observe { db in try Self.receipts(db, month: month, accountIDs: accountIDs, calendar: calendar) }
    }

    public static func receiptMonths(_ db: Database, accountIDs: Set<String>?, calendar: Calendar) throws -> [ReceiptMonth] {
        var months: [ReceiptMonth] = []
        for receipt in try receiptRecords(db, interval: nil, accountIDs: accountIDs) {
            let month = calendar.dateInterval(of: .month, for: receipt.date)?.start ?? receipt.date
            if months.last?.month != month { months.append(ReceiptMonth(month: month, count: 0, totals: [:])) }
            months[months.count - 1].count += 1
            if let amount = receipt.amount {
                months[months.count - 1].totals[receipt.currency ?? "USD", default: 0] += amount
            }
        }
        return months
    }

    public static func receipts(_ db: Database, month: Date?, accountIDs: Set<String>?, calendar: Calendar) throws -> [ReceiptRow] {
        let receipts = try receiptRecords(db, interval: month.flatMap { calendar.dateInterval(of: .month, for: $0) }, accountIDs: accountIDs)
        let messages = try messagesByKey(db, receipts.map { ($0.accountID, $0.messageID) })
        return receipts.compactMap { receipt in
            messages[receipt.accountID + "/" + receipt.messageID].map { ReceiptRow(receipt: receipt, message: $0) }
        }
    }

    static func receiptRecords(_ db: Database, interval: DateInterval?, accountIDs: Set<String>?) throws -> [Receipt] {
        let range: SQL = interval.map { "AND receipt.date >= \($0.start) AND receipt.date < \($0.end)" } ?? ""
        return try SQLRequest<Receipt>(literal: """
            SELECT receipt.* FROM receipt
            JOIN message ON message.accountID = receipt.accountID AND message.id = receipt.messageID
            WHERE message.bucket = 'receipts' AND message.isFiled AND NOT message.isTrashOrSpam \(accountScope(accountIDs)) \(range)
            ORDER BY receipt.date DESC
            """).fetchAll(db)
    }

    public func receipt(accountID: String, messageID: String) async throws -> Receipt? {
        try await writer.read { db in try Receipt.fetchOne(db, key: ["accountID": accountID, "messageID": messageID]) }
    }

    // MARK: - Calendar

    public func observeEvents(accountIDs: Set<String>? = nil) -> AsyncValueObservation<[EventRow]> {
        observe { db in try Self.events(db, accountIDs: accountIDs) }
    }

    /// Every filed event, soonest start first; the UI splits upcoming from past. When an invite was updated
    /// or canceled, the latest message about it (highest SEQUENCE, then newest) stands for the event.
    /// Attendee replies only stand in for an event no invite was stored for.
    public static func events(_ db: Database, accountIDs: Set<String>?) throws -> [EventRow] {
        let candidates = try SQLRequest<Row>(literal: """
            SELECT calendarEvent.* FROM calendarEvent
            JOIN message ON message.accountID = calendarEvent.accountID AND message.id = calendarEvent.messageID
            WHERE message.isFiled AND NOT message.isTrashOrSpam \(accountScope(accountIDs))
            """).fetchAll(db).map { try CalendarEvent(row: $0) }
        let messages = try messagesByKey(db, candidates.map { ($0.accountID, $0.messageID) })
        var latest: [String: EventRow] = [:]
        func rank(_ row: EventRow) -> (Int, Int, Date) {
            (row.event.method == .reply ? 0 : 1, row.event.sequence, row.message.internalDate)
        }
        for event in candidates {
            guard let message = messages[event.accountID + "/" + event.messageID] else { continue }
            let row = EventRow(event: event, message: message)
            let key = event.accountID + "\u{1F}" + event.uid
            if let current = latest[key], rank(current) >= rank(row) { continue }
            latest[key] = row
        }
        return latest.values.sorted { a, b in
            let (x, y) = (a.event.start ?? .distantPast, b.event.start ?? .distantPast)
            return x == y ? a.id < b.id : x < y
        }
    }

    // MARK: - Search

    /// Full-text search over subject, sender, snippet, and body, every word matched as a prefix,
    /// newest first.
    public func search(_ query: String, accountIDs: Set<String>? = nil, limit: Int = 100) async throws -> [MailMessage] {
        try await writer.read { db in try Self.search(db, query, accountIDs: accountIDs, limit: limit) }
    }

    public static func search(_ db: Database, _ query: String, accountIDs: Set<String>?, limit: Int) throws -> [MailMessage] {
        guard let pattern = prefixPattern(query) else { return [] }
        return try SQLRequest<MailMessage>(literal: """
            SELECT message.* FROM message
            JOIN message_fts ON message_fts.rowid = message.rowid AND message_fts MATCH \(pattern)
            WHERE NOT message.isTrashOrSpam \(accountScope(accountIDs))
            ORDER BY message.internalDate DESC
            LIMIT \(limit)
            """).fetchAll(db)
    }

    /// Every typed token becomes a quoted prefix term: "inv acm" matches "Invoice from Acme".
    static func prefixPattern(_ text: String) -> String? {
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    // MARK: - Observation

    /// Values from `fetch`, again whenever the tables it read change. Iterate in a task the view owns.
    public func observe<T: Sendable>(_ fetch: @escaping @Sendable (Database) throws -> T) -> AsyncValueObservation<T> {
        ValueObservation.tracking(fetch).values(in: writer)
    }

    // MARK: - Helpers

    static func accountScope(_ accountIDs: Set<String>?) -> SQL {
        guard let accountIDs else { return "" }
        return "AND message.accountID IN \(Array(accountIDs))"
    }

    /// Messages that appear in a bucket's view: inbox mail still in INBOX, sorted mail still filed.
    static func bucketFilter(_ bucket: Bucket) -> SQL {
        bucket == .inbox
            ? "message.bucket = 'inbox' AND message.isInInbox AND NOT message.isTrashOrSpam"
            : "message.bucket = \(bucket) AND message.isFiled AND NOT message.isTrashOrSpam"
    }

    /// The newest message of each group in a bucket, with the group's size and unread count.
    static func latestPerGroup(_ db: Database, bucket: Bucket, column: String, accountIDs: Set<String>?) throws
        -> [(latest: MailMessage, count: Int, unread: Int)] {
        let group = SQL(sql: column.quotedDatabaseIdentifier)
        let rows = try SQLRequest<Row>(literal: """
            SELECT * FROM (
                SELECT message.*,
                    ROW_NUMBER() OVER (PARTITION BY \(group) ORDER BY internalDate DESC) AS rowNumber,
                    COUNT(*) OVER (PARTITION BY \(group)) AS groupCount,
                    SUM(isUnread) OVER (PARTITION BY \(group)) AS groupUnread
                FROM message
                WHERE \(bucketFilter(bucket)) \(accountScope(accountIDs))
            )
            WHERE rowNumber = 1
            ORDER BY internalDate DESC
            """).fetchAll(db)
        return try rows.map { (try MailMessage(row: $0), $0["groupCount"], $0["groupUnread"]) }
    }

    /// A bucket's messages newest first, all of them or those whose `column` equals `value`.
    static func messages(_ db: Database, bucket: Bucket, column: String, value: String?, accountIDs: Set<String>?,
                         limit: Int, before: Date? = nil) throws -> [MailMessage] {
        let match: SQL = value.map { "AND \(SQL(sql: column.quotedDatabaseIdentifier)) = \($0)" } ?? ""
        let beforeClause: SQL = before.map { "AND message.internalDate < \($0)" } ?? ""
        return try SQLRequest<MailMessage>(literal: """
            SELECT message.* FROM message
            WHERE \(bucketFilter(bucket)) \(match) \(accountScope(accountIDs)) \(beforeClause)
            ORDER BY internalDate DESC
            LIMIT \(limit)
            """).fetchAll(db)
    }

    /// Messages for (account, message ID) pairs, keyed "account/id".
    static func messagesByKey(_ db: Database, _ keys: [(String, String)]) throws -> [String: MailMessage] {
        guard !keys.isEmpty else { return [:] }
        let ids = Array(Set(keys.map(\.1)))
        let accounts = Array(Set(keys.map(\.0)))
        let messages = try MailMessage.filter(ids.contains(Column("id")) && accounts.contains(Column("accountID"))).fetchAll(db)
        return Dictionary(messages.map { ($0.accountID + "/" + $0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
}
