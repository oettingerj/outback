import Foundation
import GRDB

/// Reads and writes Dingo's mail cache. Every method runs off the caller's thread on the database's
/// own queue; each write is one transaction, so views never see half a sync batch.
///
/// Message IDs and label IDs are unique only within an account, so every lookup takes both.
public final class MailStore: Sendable {
    public let database: AppDatabase

    public init(database: AppDatabase) { self.database = database }

    var writer: any DatabaseWriter { database.writer }

    /// A one-shot read with any of the store's `Database` queries.
    public func read<T: Sendable>(_ fetch: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await writer.read(fetch)
    }

    // MARK: - Accounts

    /// Adds the account, or updates its name, aliases, and position. Sync state (history ID, last
    /// sync) and the date it was added are kept, because sign-in refreshes the profile without
    /// knowing them.
    public func upsert(_ account: MailAccount) async throws {
        try await writer.write { db in
            if var existing = try MailAccount.fetchOne(db, key: account.email) {
                existing.displayName = account.displayName
                existing.sendAs = account.sendAs
                existing.position = account.position
                try existing.update(db)
            } else {
                try account.insert(db)
            }
        }
    }

    public func accounts() async throws -> [MailAccount] {
        try await writer.read { db in try MailAccount.order(Column("position"), Column("addedAt")).fetchAll(db) }
    }

    /// Removes the account and everything stored for it.
    public func removeAccount(_ email: String) async throws {
        _ = try await writer.write { db in try MailAccount.deleteOne(db, key: email) }
    }

    public func historyID(accountID: String) async throws -> UInt64? {
        try await writer.read { db in try MailAccount.fetchOne(db, key: accountID)?.historyID }
    }

    /// Records where the next incremental sync starts.
    public func setHistoryID(_ historyID: UInt64, accountID: String, syncedAt: Date = Date()) async throws {
        _ = try await writer.write { db in
            try MailAccount.filter(key: accountID)
                .updateAll(db, Column("historyID").set(to: historyID), Column("lastSyncAt").set(to: syncedAt))
        }
    }

    // MARK: - Labels

    /// Replaces the account's labels with what Gmail just listed.
    public func replaceLabels(_ labels: [MailLabel], accountID: String) async throws {
        try await writer.write { db in
            try MailLabel.filter(Column("accountID") == accountID).deleteAll(db)
            for label in labels where label.accountID == accountID { try label.insert(db) }
            // Labels can arrive after the messages that carry them.
            try Self.recomputeFiled(db, accountID: accountID, messageIDs: nil)
        }
    }

    public func labels(accountID: String) async throws -> [MailLabel] {
        try await writer.read { db in
            try MailLabel.filter(Column("accountID") == accountID).order(Column("name")).fetchAll(db)
        }
    }

    // MARK: - Saving from sync

    /// Stores messages from Gmail with the bucket `bucket` picks for each (usually `Classifier.classify`),
    /// in one transaction: the message row, its body and attachments when present, and the receipt or
    /// calendar row derived from it. Saving again updates in place. A metadata-only copy (no body)
    /// keeps the body, attachments, and receipt already stored. The account must exist.
    public func save(_ messages: [ParsedMessage], bucket: (ParsedMessage) -> Bucket) async throws {
        let batch = messages.map { (message: $0, bucket: bucket($0)) }
        try await writer.write { db in
            for (message, bucket) in batch {
                let existing = try MailMessage.fetchOne(db, key: ["accountID": message.accountID, "id": message.id])
                var record = MailMessage(message, bucket: bucket, bodyState: message.body != nil ? .fetched : existing?.bodyState ?? .none)
                if message.body == nil, message.attachments.isEmpty, existing?.hasAttachments == true { record.hasAttachments = true }
                try record.upsert(db)

                if let body = message.body {
                    try Self.writeBody(db, body, attachments: message.attachments, message: record)
                } else {
                    if !message.attachments.isEmpty { try Self.replaceAttachments(db, message.attachments, message: record) }
                    if bucket == .receipts, try !Receipt.exists(db, key: Self.key(record)) {
                        try Self.receipt(for: record, body: nil).upsert(db)
                    }
                }
            }
            for (accountID, items) in Dictionary(grouping: batch, by: \.message.accountID) {
                try Self.recomputeFiled(db, accountID: accountID, messageIDs: items.map(\.message.id))
            }
        }
    }

    /// Stores a body fetched after the message's metadata, with the rows derived from it.
    /// `attachments` replaces the stored list when given.
    public func saveBody(_ body: ParsedMessage.Body, attachments: [ParsedMessage.Attachment]? = nil,
                         accountID: String, messageID: String) async throws {
        try await writer.write { db in
            guard var record = try MailMessage.fetchOne(db, key: ["accountID": accountID, "id": messageID]) else { return }
            record.bodyState = .fetched
            if let attachments { record.hasAttachments = !attachments.isEmpty }
            try record.update(db)
            try Self.writeBody(db, body, attachments: attachments, message: record)
        }
    }

    /// Marks messages whose full fetch is done but had nothing to store, so sync stops asking for them.
    public func markBodiesFetched(accountID: String, messageIDs: [String]) async throws {
        _ = try await writer.write { db in
            try MailMessage.filter(Column("accountID") == accountID && messageIDs.contains(Column("id")))
                .updateAll(db, Column("bodyState").set(to: MailMessage.BodyState.fetched))
        }
    }

    static func key(_ message: MailMessage) -> [String: (any DatabaseValueConvertible)?] {
        ["accountID": message.accountID, "messageID": message.id]
    }

    /// The body row, its search text, attachments, and the receipt and calendar rows it yields.
    static func writeBody(_ db: Database, _ body: ParsedMessage.Body, attachments: [ParsedMessage.Attachment]?, message: MailMessage) throws {
        let stored = MailBody(accountID: message.accountID, messageID: message.id, body: body)
        try stored.upsert(db)
        try db.execute(literal: """
            UPDATE message_fts SET body = \(stored.searchText)
            WHERE rowid = (SELECT rowid FROM message WHERE accountID = \(message.accountID) AND id = \(message.id))
            """)
        if let attachments { try replaceAttachments(db, attachments, message: message) }
        if message.bucket == .receipts { try receipt(for: message, body: stored).upsert(db) }
        if let calendar = body.calendar, let invite = ICalendarParser.parse(calendar), let event = invite.primaryEvent {
            let addresses = try MailAccount.fetchOne(db, key: message.accountID)?.addresses ?? [message.accountID.lowercased()]
            var row = CalendarEvent(accountID: message.accountID, messageID: message.id, method: invite.method,
                                    event: event, myAddresses: addresses)
            // An answer given in Dingo is newer than the invite's own PARTSTAT.
            if row.myResponse == nil { row.myResponse = try CalendarEvent.fetchOne(db, key: key(message))?.myResponse }
            try row.upsert(db)
        }
    }

    static func replaceAttachments(_ db: Database, _ attachments: [ParsedMessage.Attachment], message: MailMessage) throws {
        try MailAttachment.filter(Column("accountID") == message.accountID && Column("messageID") == message.id).deleteAll(db)
        for (position, attachment) in attachments.enumerated() {
            try MailAttachment(accountID: message.accountID, messageID: message.id, position: position,
                               attachmentID: attachment.attachmentID, filename: attachment.filename,
                               mimeType: attachment.mimeType, size: attachment.size).insert(db)
        }
    }

    /// Builds receipt rows, from stored bodies, for messages now in Receipts that do not have one.
    static func deriveMissingReceipts(_ db: Database, accountID: String, messageIDs: [String]) throws {
        let messages = try MailMessage.filter(Column("accountID") == accountID && messageIDs.contains(Column("id"))
                                              && Column("bucket") == Bucket.receipts).fetchAll(db)
        for message in messages where try !Receipt.exists(db, key: key(message)) {
            try receipt(for: message, body: try MailBody.fetchOne(db, key: key(message))).insert(db)
        }
    }

    static func receipt(for message: MailMessage, body: MailBody?) -> Receipt {
        ReceiptParser.parse(accountID: message.accountID, messageID: message.id, date: message.internalDate,
                            subject: message.subject, from: message.from, html: body?.html, text: body?.text)
    }

    /// Applies label changes from history sync, keeping the unread, starred, inbox, and trash flags in
    /// step. Unknown message IDs are skipped; sync fetches those as new messages.
    public func updateLabels(_ labelIDsByMessage: [String: [String]], accountID: String) async throws {
        try await writer.write { db in
            for (messageID, labelIDs) in labelIDsByMessage {
                guard var record = try MailMessage.fetchOne(db, key: ["accountID": accountID, "id": messageID]) else { continue }
                record.applyLabels(labelIDs)
                try record.update(db)
            }
            try Self.recomputeFiled(db, accountID: accountID, messageIDs: Array(labelIDsByMessage.keys))
        }
    }

    /// Sets `isFiled` from the labels: true when a message is in INBOX or carries the account's
    /// `Dingo/*` label for its own bucket. Done in SQL so every writer shares one rule; nil
    /// `accountID` or `messageIDs` widens it to every account or every message.
    static func recomputeFiled(_ db: Database, accountID: String?, messageIDs: [String]?) throws {
        let cases = Bucket.sorted.compactMap { bucket in
            bucket.labelName.map { "WHEN \(bucket.rawValue) THEN \($0)" as SQL }
        }.joined(separator: " ")
        var scope: SQL = "1"
        if let accountID { scope = "accountID = \(accountID)" }
        if let messageIDs { scope = "\(scope) AND id IN \(messageIDs)" }
        try db.execute(literal: """
            UPDATE message SET isFiled = EXISTS (
                SELECT 1 FROM json_each(message.labelIDsJSON) AS assigned
                WHERE assigned.value = 'INBOX'
                   OR assigned.value IN (SELECT label.id FROM label
                                         WHERE label.accountID = message.accountID
                                           AND label.name = (CASE message.bucket \(cases) END))
            )
            WHERE \(scope)
            """)
    }

    /// Deletes messages and everything derived from them, as when history sync reports them gone.
    public func remove(accountID: String, messageIDs: [String]) async throws {
        _ = try await writer.write { db in
            try MailMessage.filter(Column("accountID") == accountID && messageIDs.contains(Column("id"))).deleteAll(db)
        }
    }

    // MARK: - Sync bookkeeping

    /// Messages stored from metadata only, newest first, for sync to fetch in full.
    public func messageIDsMissingBodies(accountID: String, newerThan date: Date? = nil, limit: Int = 100) async throws -> [String] {
        try await writer.read { db in
            var request = MailMessage.filter(Column("accountID") == accountID && Column("bodyState") == MailMessage.BodyState.none
                                             && !Column("isTrashOrSpam"))
            if let date { request = request.filter(Column("internalDate") > date) }
            return try String.fetchAll(db, request.select(Column("id")).order(Column("internalDate").desc).limit(limit))
        }
    }

    public func knownMessageIDs(accountID: String) async throws -> Set<String> {
        try await writer.read { db in
            try Set(String.fetchAll(db, MailMessage.filter(Column("accountID") == accountID).select(Column("id"))))
        }
    }

    // MARK: - Reading messages

    public func message(accountID: String, messageID: String) async throws -> MailMessage? {
        try await writer.read { db in try MailMessage.fetchOne(db, key: ["accountID": accountID, "id": messageID]) }
    }

    /// The thread's messages oldest first, without trash and spam.
    public func thread(accountID: String, threadID: String) async throws -> [MailMessage] {
        try await writer.read { db in try Self.thread(db, accountID: accountID, threadID: threadID) }
    }

    public static func thread(_ db: Database, accountID: String, threadID: String) throws -> [MailMessage] {
        try MailMessage
            .filter(Column("accountID") == accountID && Column("threadID") == threadID && !Column("isTrashOrSpam"))
            .order(Column("internalDate"))
            .fetchAll(db)
    }

    public func body(accountID: String, messageID: String) async throws -> MailBody? {
        try await writer.read { db in try MailBody.fetchOne(db, key: ["accountID": accountID, "messageID": messageID]) }
    }

    public func attachments(accountID: String, messageID: String) async throws -> [MailAttachment] {
        try await writer.read { db in
            try MailAttachment.filter(Column("accountID") == accountID && Column("messageID") == messageID)
                .order(Column("position")).fetchAll(db)
        }
    }

    // MARK: - Sender rules

    /// Adds a rule, or changes the bucket of the rule already set for that matcher and account.
    @discardableResult
    public func setRule(matcher: String, bucket: Bucket, accountID: String? = nil) async throws -> SenderRule {
        let normalized = SenderRule.normalize(matcher)
        return try await writer.write { db in
            if var rule = try SenderRule.filter(Column("accountID") == accountID && Column("matcher") == normalized).fetchOne(db) {
                rule.bucket = bucket
                try rule.update(db)
                return rule
            }
            var rule = SenderRule(accountID: accountID, matcher: normalized, bucket: bucket)
            try rule.insert(db)
            return rule
        }
    }

    public func rules() async throws -> [SenderRule] {
        try await writer.read { db in try SenderRule.order(Column("createdAt").desc).fetchAll(db) }
    }

    public func deleteRule(id: Int64) async throws {
        _ = try await writer.write { db in try SenderRule.deleteOne(db, key: id) }
    }

    /// The rule that applies to mail from `address` in `accountID`, by `SenderRuleLookup`'s precedence.
    public func rule(for address: EmailAddress, accountID: String) async throws -> SenderRule? {
        let matchers = SenderRuleLookup.matchers(for: address)
        let rules = try await writer.read { db in
            try SenderRule.filter(matchers.contains(Column("matcher"))
                                  && (Column("accountID") == nil || Column("accountID") == accountID)).fetchAll(db)
        }
        return SenderRuleLookup(rules).rule(for: address, accountID: accountID)
    }

    public func ruleLookup() async throws -> SenderRuleLookup {
        SenderRuleLookup(try await rules())
    }

    /// A classifier loaded with the rules and the account's label names.
    public func classifier(accountID: String) async throws -> Classifier {
        let (rules, labels) = try await writer.read { db in
            (try SenderRule.fetchAll(db), try MailLabel.filter(Column("accountID") == accountID).fetchAll(db))
        }
        return Classifier(rules: SenderRuleLookup(rules),
                          labelNames: Dictionary(labels.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }))
    }
}
