import Foundation
import GRDB

/// Which messages a user action applies to: a list, or every message in a thread.
public enum MessageSelection: Sendable, Equatable {
    case messages([String])
    case thread(String)
}

/// The labels and buckets messages had before an action, so the UI can undo it, or put things back
/// when the Gmail call behind an optimistic change fails.
public struct MessageStateSnapshot: Sendable, Equatable {
    public var accountID: String
    public var labelIDs: [String: [String]]
    public var buckets: [String: Bucket]

    /// The messages the action touched, for the Gmail call that mirrors it.
    public var messageIDs: [String] { labelIDs.keys.sorted() }
}

/// The local half of the actions the UI applies optimistically. Each changes the stored labels the
/// way Gmail will, so lists update at once, and returns a snapshot for `restore(_:)`.
extension MailStore {
    @discardableResult
    public func setUnread(_ unread: Bool, _ selection: MessageSelection, accountID: String) async throws -> MessageStateSnapshot {
        try await change(selection, accountID: accountID) { labels, _ in Self.toggle(&labels, "UNREAD", on: unread) }
    }

    @discardableResult
    public func setStarred(_ starred: Bool, _ selection: MessageSelection, accountID: String) async throws -> MessageStateSnapshot {
        try await change(selection, accountID: accountID) { labels, _ in Self.toggle(&labels, "STARRED", on: starred) }
    }

    /// Removes INBOX and every `Dingo/*` label, so the messages leave whichever view showed them.
    @discardableResult
    public func archive(_ selection: MessageSelection, accountID: String) async throws -> MessageStateSnapshot {
        try await change(selection, accountID: accountID) { labels, dingoLabels in
            labels.removeAll { $0 == "INBOX" || dingoLabels.contains($0) }
        }
    }

    /// Applies label edits as Gmail's modify calls will, so the UI can update before Gmail answers.
    /// Removals apply before additions.
    @discardableResult
    public func setLabels(accountID: String, changes: [String: (add: [String], remove: [String])]) async throws -> MessageStateSnapshot {
        try await writer.write { db in
            let messages = try Self.messages(db, .messages(Array(changes.keys)), accountID: accountID)
            for var message in messages {
                guard let edit = changes[message.id] else { continue }
                var labels = message.labelIDs.filter { !edit.remove.contains($0) }
                for label in edit.add where !labels.contains(label) { labels.append(label) }
                message.applyLabels(labels)
                try message.update(db)
            }
            try Self.recomputeFiled(db, accountID: accountID, messageIDs: messages.map(\.id))
            return Self.snapshot(messages, accountID: accountID)
        }
    }

    /// Adds TRASH, which hides the messages from every view.
    @discardableResult
    public func trash(_ selection: MessageSelection, accountID: String) async throws -> MessageStateSnapshot {
        try await change(selection, accountID: accountID) { labels, _ in Self.toggle(&labels, "TRASH", on: true) }
    }

    /// Moves messages to a bucket with the labels Gmail will end up with: a sorted bucket takes its
    /// `Dingo/*` label and INBOX stays as it was, so nothing skips Gmail's Inbox; the inbox takes
    /// INBOX back. With no `Dingo/*` label yet, INBOX keeps the message filed until sync creates it. For a
    /// thread, the user's own sent mail and drafts stay where they are, as the classifier would put
    /// them. Moving into Receipts derives receipt rows from stored bodies.
    @discardableResult
    public func moveToBucket(_ bucket: Bucket, _ selection: MessageSelection, accountID: String) async throws -> MessageStateSnapshot {
        try await writer.write { db in
            let dingoLabels = try Self.dingoLabelIDs(db, accountID: accountID)
            var messages = try Self.messages(db, selection, accountID: accountID)
            if case .thread = selection {
                let theirs = messages.filter { !$0.labelIDs.contains("SENT") && !$0.labelIDs.contains("DRAFT") }
                if !theirs.isEmpty { messages = theirs }
            }
            let snapshot = Self.snapshot(messages, accountID: accountID)
            for var message in messages {
                var labels = message.labelIDs.filter { !dingoLabels.values.contains($0) }
                if let labelName = bucket.labelName, let id = dingoLabels[labelName] {
                    labels.append(id)
                } else if bucket.labelName == nil {
                    Self.toggle(&labels, "INBOX", on: true)
                }
                message.applyLabels(labels)
                message.bucket = bucket
                try message.update(db)
            }
            try Self.deriveMissingReceipts(db, accountID: accountID, messageIDs: messages.map(\.id))
            try Self.recomputeFiled(db, accountID: accountID, messageIDs: messages.map(\.id))
            return snapshot
        }
    }

    /// Puts labels and buckets back as the snapshot recorded them.
    public func restore(_ snapshot: MessageStateSnapshot) async throws {
        try await writer.write { db in
            for (messageID, labelIDs) in snapshot.labelIDs {
                guard var message = try MailMessage.fetchOne(db, key: ["accountID": snapshot.accountID, "id": messageID]) else { continue }
                message.applyLabels(labelIDs)
                if let bucket = snapshot.buckets[messageID] { message.bucket = bucket }
                try message.update(db)
            }
            try Self.recomputeFiled(db, accountID: snapshot.accountID, messageIDs: snapshot.messageIDs)
        }
    }

    /// Records the user's answer on every stored copy of the event, so it survives the next sync.
    /// Returns the answer it replaced, for undo.
    @discardableResult
    public func setMyResponse(accountID: String, messageID: String, response: ParticipationStatus?) async throws -> ParticipationStatus? {
        try await writer.write { db in
            guard let event = try CalendarEvent.fetchOne(db, key: ["accountID": accountID, "messageID": messageID]) else { return nil }
            try CalendarEvent.filter(Column("accountID") == accountID && Column("uid") == event.uid)
                .updateAll(db, Column("myResponse").set(to: response))
            return event.myResponse
        }
    }

    // MARK: - Helpers

    /// Edits each selected message's labels; `edit` also gets the account's `Dingo/*` label IDs.
    func change(_ selection: MessageSelection, accountID: String,
                _ edit: @escaping @Sendable (inout [String], Set<String>) -> Void) async throws -> MessageStateSnapshot {
        try await writer.write { db in
            let dingoLabels = Set(try Self.dingoLabelIDs(db, accountID: accountID).values)
            let messages = try Self.messages(db, selection, accountID: accountID)
            let snapshot = Self.snapshot(messages, accountID: accountID)
            for var message in messages {
                var labels = message.labelIDs
                edit(&labels, dingoLabels)
                guard labels != message.labelIDs else { continue }
                message.applyLabels(labels)
                try message.update(db)
            }
            try Self.recomputeFiled(db, accountID: accountID, messageIDs: messages.map(\.id))
            return snapshot
        }
    }

    static func messages(_ db: Database, _ selection: MessageSelection, accountID: String) throws -> [MailMessage] {
        switch selection {
        case .messages(let ids):
            try MailMessage.filter(Column("accountID") == accountID && ids.contains(Column("id"))).fetchAll(db)
        case .thread(let threadID):
            try MailMessage.filter(Column("accountID") == accountID && Column("threadID") == threadID).fetchAll(db)
        }
    }

    static func snapshot(_ messages: [MailMessage], accountID: String) -> MessageStateSnapshot {
        MessageStateSnapshot(accountID: accountID,
                             labelIDs: Dictionary(messages.map { ($0.id, $0.labelIDs) }, uniquingKeysWith: { a, _ in a }),
                             buckets: Dictionary(messages.map { ($0.id, $0.bucket) }, uniquingKeysWith: { a, _ in a }))
    }

    /// `Dingo/*` label name to the account's label ID.
    static func dingoLabelIDs(_ db: Database, accountID: String) throws -> [String: String] {
        let labels = try MailLabel.filter(Column("accountID") == accountID && Column("name").like("Dingo/%")).fetchAll(db)
        return Dictionary(labels.map { ($0.name, $0.id) }, uniquingKeysWith: { a, _ in a })
    }

    static func toggle(_ labels: inout [String], _ label: String, on: Bool) {
        if on {
            if !labels.contains(label) { labels.append(label) }
        } else {
            labels.removeAll { $0 == label }
        }
    }
}
