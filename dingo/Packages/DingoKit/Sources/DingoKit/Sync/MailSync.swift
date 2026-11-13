import Foundation
import GRDB

/// Keeps one account's local cache in step with Gmail, and keeps Gmail in step with Dingo's buckets.
///
/// The first sync lists the last `windowDays` of mail, fetches the newest two weeks in full (so
/// receipts and invites can be read from their bodies) and the rest as metadata, sorts it, and
/// labels it in Gmail. Later syncs read Gmail's history since the stored history ID and apply only
/// what changed. When Gmail has forgotten that history, the first sync runs again.
public actor MailSync {
    public let account: String
    public let client: GmailClient
    let store: MailStore
    /// How far back a first sync reaches.
    public var windowDays: Int
    /// Whether sorted mail leaves Gmail's Inbox; the bucket label is applied either way.
    public var archivesSortedMail: Bool

    /// Label name to ID for the bucket labels, created on first sync.
    private var bucketLabels: [Bucket: String] = [:]
    private var labelNames: [String: String] = [:]
    private var running: Task<SyncReport, Error>?

    public struct SyncReport: Sendable, Equatable {
        /// New mail that landed in the Inbox, for notifications.
        public var newInbox: [MailMessage] = []
        public var added = 0
        public var changed = 0
        public var removed = 0
        public var wasFullSync = false
    }

    public init(account: String, client: GmailClient, store: MailStore, windowDays: Int = 90, archivesSortedMail: Bool = true) {
        self.account = account
        self.client = client
        self.store = store
        self.windowDays = windowDays
        self.archivesSortedMail = archivesSortedMail
    }

    public func configure(windowDays: Int, archivesSortedMail: Bool) {
        self.windowDays = windowDays
        self.archivesSortedMail = archivesSortedMail
    }

    /// Runs one sync, joining one already in progress.
    @discardableResult
    public func sync() async throws -> SyncReport {
        if let running { return try await running.value }
        let task = Task { try await self.performSync() }
        running = task
        defer { running = nil }
        return try await task.value
    }

    private func performSync() async throws -> SyncReport {
        try await ensureLabels()
        if let historyID = try await store.historyID(accountID: account) {
            do {
                return try await incremental(from: historyID)
            } catch GmailError.historyExpired {
                return try await full()
            }
        }
        return try await full()
    }

    // MARK: Labels

    /// Lists the account's labels, creating the four Dingo bucket labels where missing.
    private func ensureLabels() async throws {
        var labels = try await client.listLabels()
        for bucket in Bucket.sorted {
            guard let name = bucket.labelName, !labels.contains(where: { $0.name == name }) else { continue }
            do {
                labels.append(try await client.createLabel(name: name))
            } catch GmailError.alreadyExists {
                labels = try await client.listLabels()
            }
        }
        labelNames = Dictionary(labels.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        bucketLabels = Dictionary(uniqueKeysWithValues: Bucket.sorted.compactMap { bucket in
            labels.first { $0.name == bucket.labelName }.map { (bucket, $0.id) }
        })
        try await store.replaceLabels(labels.map { MailLabel(accountID: account, id: $0.id, name: $0.name, type: $0.type ?? "user") },
                                      accountID: account)
    }

    public func labelID(for bucket: Bucket) -> String? { bucketLabels[bucket] }

    // MARK: Full sync

    private func full() async throws -> SyncReport {
        let profile = try await client.profile()
        var ids: [String] = []
        var pageToken: String?
        repeat {
            let page = try await client.listMessages(query: "newer_than:\(windowDays)d -in:chats", pageToken: pageToken, maxResults: 500)
            ids += page.messages.map(\.id)
            pageToken = page.nextPageToken
        } while pageToken != nil && ids.count < 20_000

        let known = try await store.knownMessageIDs(accountID: account)
        let fresh = ids.filter { !known.contains($0) }
        // Newest first: the list comes back newest first, so the Inbox fills from the top.
        let cutoff = Date().addingTimeInterval(-14 * 86_400)
        var report = SyncReport(wasFullSync: true)
        for chunk in fresh.chunked(200) {
            let metadata = try await client.messages(ids: chunk, format: .metadata)
            let recent = metadata.filter { ($0.internalDate ?? .distantPast) >= cutoff }.map(\.id)
            let full = recent.isEmpty ? [] : try await client.messages(ids: recent, format: .full)
            let fullByID = Dictionary(full.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let parsed = metadata.map { GmailMessageDecoder.decode(fullByID[$0.id] ?? $0, accountID: account) }
            let saved = try await save(parsed)
            report.added += saved.count
        }
        // Messages gone from the window, or deleted, leave the cache.
        let stale = known.subtracting(ids)
        if !stale.isEmpty {
            try await store.remove(accountID: account, messageIDs: Array(stale))
            report.removed = stale.count
        }
        try await store.setHistoryID(profile.historyID, accountID: account)
        return report
    }

    // MARK: Incremental sync

    private func incremental(from historyID: UInt64) async throws -> SyncReport {
        var added: [String] = []
        var deleted: Set<String> = []
        var labelChanged: [String: [String]] = [:]
        var pageToken: String?
        var latest = historyID
        repeat {
            let page = try await client.history(startHistoryID: historyID, pageToken: pageToken)
            for entry in page.history {
                added += entry.messagesAdded.map(\.message.id)
                deleted.formUnion(entry.messagesDeleted.map(\.message.id))
                for change in entry.labelsAdded + entry.labelsRemoved {
                    labelChanged[change.message.id] = change.message.labelIDs
                }
            }
            latest = max(latest, page.historyID)
            pageToken = page.nextPageToken
        } while pageToken != nil

        var report = SyncReport()
        let known = try await store.knownMessageIDs(accountID: account)
        let newIDs = Array(Set(added).subtracting(deleted).subtracting(known))
        // Label changes on messages not yet stored arrive with their full fetch below.
        let changed = labelChanged.filter { known.contains($0.key) && !deleted.contains($0.key) }
        if !changed.isEmpty {
            // History's label lists can be partial; refetch the changed messages' labels to be exact.
            let fresh = try await client.messages(ids: Array(changed.keys), format: .minimal)
            let labels = Dictionary(fresh.map { ($0.id, $0.labelIDs) }, uniquingKeysWith: { a, _ in a })
            try await store.updateLabels(labels, accountID: account)
            try await rebucketAfterLabelChange(Array(labels.keys))
            report.changed = labels.count
        }
        for chunk in newIDs.chunked(100) {
            let messages = try await client.messages(ids: chunk, format: .full)
            let saved = try await save(messages.map { GmailMessageDecoder.decode($0, accountID: account) })
            report.added += saved.count
            report.newInbox += saved.filter { $0.bucket == .inbox && $0.isInInbox && $0.isUnread }
        }
        if !deleted.isEmpty {
            try await store.remove(accountID: account, messageIDs: Array(deleted))
            report.removed = deleted.count
        }
        try await store.setHistoryID(latest, accountID: account)
        return report
    }

    // MARK: Sorting and mirroring

    /// Classifies and stores messages, then labels the sorted ones in Gmail.
    private func save(_ messages: [ParsedMessage]) async throws -> [MailMessage] {
        guard !messages.isEmpty else { return [] }
        let classifier = Classifier(rules: try await store.ruleLookup(), labelNames: labelNames)
        let buckets = Dictionary(messages.map { ($0.id, classifier.classify($0)) }, uniquingKeysWith: { a, _ in a })
        try await store.save(messages) { buckets[$0.id] ?? .inbox }
        let saved = try await store.messages(accountID: account, ids: messages.map(\.id))
        try await mirror(saved)
        return try await store.messages(accountID: account, ids: messages.map(\.id))
    }

    /// Gives sorted messages their bucket label in Gmail and takes them out of the Inbox; takes the
    /// label off anything Dingo now keeps in the Inbox. Sent mail and drafts are never touched.
    public func mirror(_ messages: [MailMessage]) async throws {
        var groups: [[String]: (add: [String], remove: [String], ids: [String])] = [:]
        let allBucketLabels = Set(bucketLabels.values)
        for message in messages where !message.isTrashOrSpam && !message.labelIDs.contains("DRAFT") {
            let labels = Set(message.labelIDs)
            var add: [String] = []
            var remove: [String] = []
            if message.bucket == .inbox {
                remove = Array(labels.intersection(allBucketLabels))
            } else if let label = bucketLabels[message.bucket] {
                if !labels.contains(label) { add.append(label) }
                remove = Array(labels.intersection(allBucketLabels).subtracting([label]))
                if archivesSortedMail, labels.contains("INBOX"), !labels.contains("SENT") { remove.append("INBOX") }
            }
            guard !add.isEmpty || !remove.isEmpty else { continue }
            let key = add.sorted() + ["|"] + remove.sorted()
            groups[key, default: (add, remove, [])].ids.append(message.id)
        }
        var updated: [String: [String]] = [:]
        for (_, group) in groups {
            for chunk in group.ids.chunked(1000) {
                try await client.batchModify(ids: chunk, add: group.add, remove: group.remove)
            }
            for message in messages where group.ids.contains(message.id) {
                updated[message.id] = Array(Set(message.labelIDs).union(group.add).subtracting(group.remove))
            }
        }
        if !updated.isEmpty { try await store.updateLabels(updated, accountID: account) }
    }

    /// A Dingo label added or removed elsewhere (Gmail web, the phone) moves the message here too:
    /// a bucket label wins; a message put back in the Inbox without one returns to the Inbox.
    private func rebucketAfterLabelChange(_ ids: [String]) async throws {
        let messages = try await store.messages(accountID: account, ids: ids)
        var moves: [Bucket: [String]] = [:]
        for message in messages {
            let labelled = message.labelIDs.lazy.compactMap { self.labelNames[$0].flatMap(Bucket.init(labelName:)) }.first
            if let labelled, labelled != message.bucket {
                moves[labelled, default: []].append(message.id)
            } else if labelled == nil, message.bucket != .inbox, message.isInInbox {
                moves[.inbox, default: []].append(message.id)
            }
        }
        for (bucket, ids) in moves { try await store.setBucket(bucket, accountID: account, messageIDs: ids) }
    }

    // MARK: Bodies

    /// Fetches and stores one message's full body; returns it.
    @discardableResult
    public func fetchBody(messageID: String) async throws -> MailBody? {
        let message = try await client.message(id: messageID, format: .full)
        let parsed = GmailMessageDecoder.decode(message, accountID: account)
        if let body = parsed.body {
            try await store.saveBody(body, attachments: parsed.attachments, accountID: account, messageID: messageID)
        } else {
            try await store.markBodiesFetched(accountID: account, messageIDs: [messageID])
        }
        return try await store.body(accountID: account, messageID: messageID)
    }

    /// Fills in bodies for recent mail stored from metadata, so buckets open without waiting.
    public func prefetchBodies(newerThan days: Int = 14, limit: Int = 200) async throws {
        let ids = try await store.messageIDsMissingBodies(accountID: account, newerThan: Date().addingTimeInterval(-Double(days) * 86_400), limit: limit)
        for chunk in ids.chunked(50) {
            let messages = try await client.messages(ids: chunk, format: .full)
            var empty: [String] = []
            for message in messages {
                let parsed = GmailMessageDecoder.decode(message, accountID: account)
                if let body = parsed.body {
                    try await store.saveBody(body, attachments: parsed.attachments, accountID: account, messageID: message.id)
                } else {
                    empty.append(message.id)
                }
            }
            let missing = Set(chunk).subtracting(messages.map(\.id))
            empty += missing
            if !empty.isEmpty { try await store.markBodiesFetched(accountID: account, messageIDs: empty) }
        }
    }

    // MARK: Search

    /// Gmail's own search, for mail outside the local window. Results are stored (and sorted) so
    /// they open like any other message.
    public func search(_ query: String, limit: Int = 50) async throws -> [MailMessage] {
        let page = try await client.listMessages(query: query, maxResults: limit)
        let ids = page.messages.map(\.id)
        guard !ids.isEmpty else { return [] }
        let known = try await store.knownMessageIDs(accountID: account)
        let missing = ids.filter { !known.contains($0) }
        if !missing.isEmpty {
            let metadata = try await client.messages(ids: missing, format: .metadata)
            _ = try await save(metadata.map { GmailMessageDecoder.decode($0, accountID: account) })
        }
        return try await store.messages(accountID: account, ids: ids)
    }
}

extension MailStore {
    /// Messages by ID, in the order given.
    public func messages(accountID: String, ids: [String]) async throws -> [MailMessage] {
        guard !ids.isEmpty else { return [] }
        let found = try await writer.read { db in
            try MailMessage.filter(Column("accountID") == accountID && ids.contains(Column("id"))).fetchAll(db)
        }
        let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byID[$0] }
    }

    /// Moves messages to a bucket locally; Gmail labels follow through `MailSync.mirror`. Labels are
    /// left as they are, since sync calls this once Gmail's labels are already the truth.
    public func setBucket(_ bucket: Bucket, accountID: String, messageIDs: [String]) async throws {
        try await writer.write { db in
            try MailMessage.filter(Column("accountID") == accountID && messageIDs.contains(Column("id")))
                .updateAll(db, Column("bucket").set(to: bucket))
            // The Receipts views read receipt rows, so build them for mail moved in.
            if bucket == .receipts { try Self.deriveMissingReceipts(db, accountID: accountID, messageIDs: messageIDs) }
            // Filed depends on the bucket: the label that keeps a message filed is its bucket's.
            try Self.recomputeFiled(db, accountID: accountID, messageIDs: messageIDs)
        }
    }

    /// People you've written to or heard from, most frequent first, for compose completions.
    public func contacts(matching prefix: String, limit: Int = 8) async throws -> [EmailAddress] {
        let pattern = prefix.lowercased() + "%"
        let word = "% " + prefix.lowercased() + "%"
        return try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT fromName, fromEmail, COUNT(*) AS n FROM message
                WHERE (LOWER(fromEmail) LIKE ? OR LOWER(fromName) LIKE ? OR LOWER(fromName) LIKE ?)
                  AND fromEmail NOT LIKE '%noreply%' AND fromEmail NOT LIKE '%no-reply%' AND listID IS NULL
                GROUP BY LOWER(fromEmail) ORDER BY n DESC LIMIT ?
                """, arguments: [pattern, pattern, word, limit])
            return rows.map { EmailAddress(name: $0["fromName"], email: $0["fromEmail"]) }
        }
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

/// The observation type the app's views read; GRDB stays an implementation detail of DingoKit.
public typealias MailObservation<T: Sendable> = AsyncValueObservation<T>

extension MailStore {
    /// Signed-in accounts in sidebar order, updating as accounts are added, removed, or synced.
    public func observeAccounts() -> AsyncValueObservation<[MailAccount]> {
        observe { db in try MailAccount.order(Column("position"), Column("addedAt")).fetchAll(db) }
    }
}

extension MailStore {
    /// A sender's mail, newest first, for moving it all when a sender rule is made.
    public func messages(from email: String, accountIDs: Set<String>?, limit: Int = 500) async throws -> [MailMessage] {
        try await writer.read { db in
            var request = MailMessage.filter(Column("fromEmail") == email.lowercased() && !Column("isTrashOrSpam"))
            if let accountIDs { request = request.filter(accountIDs.contains(Column("accountID"))) }
            return try request.order(Column("internalDate").desc).limit(limit).fetchAll(db)
        }
    }
}
