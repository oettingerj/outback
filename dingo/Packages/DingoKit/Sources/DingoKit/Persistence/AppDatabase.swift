import Eucalyptus
import Foundation
import GRDB

/// Dingo's SQLite database: accounts, labels, messages and their bodies, sender rules, and the rows
/// derived for the bucket views (receipts, calendar events). Gmail is the source of truth; this is
/// a cache that sync can rebuild, so every table hangs off an account and is removed with it.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// The on-disk database in Dingo's Application Support folder.
    public static func openDefault() throws -> AppDatabase {
        let directory = try AppSupport.directory()
        var config = Configuration()
        config.qos = .userInitiated
        let pool = try DatabasePool(path: directory.appendingPathComponent("dingo.sqlite").path, configuration: config)
        return try AppDatabase(pool)
    }

    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "account") { t in
                t.primaryKey("email", .text)
                t.column("displayName", .text)
                t.column("addedAt", .datetime).notNull()
                t.column("historyID", .integer)
                t.column("lastSyncAt", .datetime)
                t.column("sendAs", .jsonText).notNull().defaults(to: "[]")
                t.column("position", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "label") { t in
                t.primaryKey {
                    t.column("accountID", .text).references("account", onDelete: .cascade)
                    t.column("id", .text)
                }
                t.column("name", .text).notNull()
                t.column("type", .text).notNull()
            }
            try db.create(table: "message") { t in
                t.primaryKey {
                    t.column("accountID", .text).references("account", onDelete: .cascade)
                    t.column("id", .text)
                }
                t.column("threadID", .text).notNull()
                t.column("historyID", .integer).notNull()
                t.column("internalDate", .datetime).notNull().indexed()
                t.column("fromName", .text)
                t.column("fromEmail", .text).notNull().indexed()
                t.column("fromDomain", .text).notNull()
                t.column("toJSON", .jsonText).notNull()
                t.column("ccJSON", .jsonText).notNull()
                t.column("replyTo", .text)
                t.column("subject", .text).notNull()
                t.column("snippet", .text).notNull()
                t.column("labelIDsJSON", .jsonText).notNull()
                t.column("bucket", .text).notNull().indexed()
                t.column("isUnread", .boolean).notNull()
                t.column("isStarred", .boolean).notNull()
                t.column("isInInbox", .boolean).notNull()
                // TRASH or SPAM: kept so label sync stays exact, hidden from every view.
                t.column("isTrashOrSpam", .boolean).notNull()
                t.column("hasAttachments", .boolean).notNull()
                t.column("messageIDHeader", .text)
                t.column("inReplyTo", .text)
                t.column("references", .text)
                t.column("listID", .text)
                t.column("listUnsubscribe", .text)
                t.column("listUnsubscribePost", .text)
                // The notifications view groups by this: a GitHub repo, else the sender's domain.
                t.column("source", .text).notNull().indexed()
                t.column("bodyState", .text).notNull()
            }
            try db.create(index: "message_bucket_date", on: "message", columns: ["bucket", "internalDate"])
            try db.create(index: "message_thread", on: "message", columns: ["accountID", "threadID"])

            try db.create(table: "messageBody") { t in
                t.primaryKey {
                    t.column("accountID", .text)
                    t.column("messageID", .text)
                }
                t.foreignKey(["accountID", "messageID"], references: "message", columns: ["accountID", "id"], onDelete: .cascade)
                t.column("html", .text)
                t.column("text", .text)
                t.column("calendar", .text)
                t.column("inlineJSON", .jsonText).notNull()
            }
            try db.create(table: "attachment") { t in
                t.primaryKey {
                    t.column("accountID", .text)
                    t.column("messageID", .text)
                    t.column("position", .integer)
                }
                t.foreignKey(["accountID", "messageID"], references: "message", columns: ["accountID", "id"], onDelete: .cascade)
                t.column("attachmentID", .text)
                t.column("filename", .text).notNull()
                t.column("mimeType", .text).notNull()
                t.column("size", .integer).notNull()
            }
            try db.create(table: "senderRule") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("accountID", .text).references("account", onDelete: .cascade)
                t.column("matcher", .text).notNull()
                t.column("bucket", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            // A plain UNIQUE treats NULLs as distinct, so global rules (NULL account) need the
            // IFNULL expression to stay one per matcher.
            try db.execute(sql: "CREATE UNIQUE INDEX senderRule_matcher ON senderRule (IFNULL(accountID, ''), matcher)")

            try db.create(table: "receipt") { t in
                t.primaryKey {
                    t.column("accountID", .text)
                    t.column("messageID", .text)
                }
                t.foreignKey(["accountID", "messageID"], references: "message", columns: ["accountID", "id"], onDelete: .cascade)
                t.column("merchant", .text)
                t.column("amount", .text) // Decimal as text, exact
                t.column("currency", .text)
                t.column("orderNumber", .text)
                t.column("status", .text).notNull()
                t.column("date", .datetime).notNull().indexed()
            }
            try db.create(table: "calendarEvent") { t in
                t.primaryKey {
                    t.column("accountID", .text)
                    t.column("messageID", .text)
                }
                t.foreignKey(["accountID", "messageID"], references: "message", columns: ["accountID", "id"], onDelete: .cascade)
                t.column("uid", .text).notNull()
                t.column("method", .text).notNull()
                t.column("sequence", .integer).notNull()
                t.column("summary", .text)
                t.column("start", .datetime).indexed()
                t.column("end", .datetime)
                t.column("isAllDay", .boolean).notNull()
                t.column("timeZone", .text)
                t.column("location", .text)
                t.column("notes", .text)
                t.column("organizerName", .text)
                t.column("organizerEmail", .text)
                t.column("attendeesJSON", .jsonText).notNull()
                t.column("myResponse", .text)
                t.column("url", .text)
            }
            try db.create(index: "calendarEvent_uid", on: "calendarEvent", columns: ["accountID", "uid"])

            // One full-text index per message, holding header fields and body text together so a
            // query like "invoice acme" matches when one word is in the subject and one in the body.
            // Header columns follow `message` through triggers; the body column is written by
            // MailStore when a body arrives, because it needs HTML stripped to text first. A
            // regular (not external-content) table lets those two writers update columns independently.
            try db.create(virtualTable: "message_fts", using: FTS5()) { t in
                t.tokenizer = .unicode61()
                t.prefixes = [2, 3]
                t.column("subject")
                t.column("fromName")
                t.column("fromEmail")
                t.column("snippet")
                t.column("body")
            }
            try db.execute(sql: """
                CREATE TRIGGER message_fts_insert AFTER INSERT ON message BEGIN
                    INSERT INTO message_fts(rowid, subject, fromName, fromEmail, snippet)
                    VALUES (new.rowid, new.subject, new.fromName, new.fromEmail, new.snippet);
                END;
                CREATE TRIGGER message_fts_update AFTER UPDATE OF subject, fromName, fromEmail, snippet ON message BEGIN
                    UPDATE message_fts SET subject = new.subject, fromName = new.fromName,
                        fromEmail = new.fromEmail, snippet = new.snippet
                    WHERE rowid = new.rowid;
                END;
                CREATE TRIGGER message_fts_delete AFTER DELETE ON message BEGIN
                    DELETE FROM message_fts WHERE rowid = old.rowid;
                END;
                """)
        }
        migrator.registerMigration("v2") { db in
            // Filed: still in INBOX, or still carrying its bucket's Dingo label. Archiving removes
            // both, and the message leaves every bucket view. MailStore.recomputeFiled keeps it current.
            try db.alter(table: "message") { t in
                t.add(column: "isFiled", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "message_bucket_filed_date", on: "message", columns: ["bucket", "isFiled", "internalDate"])
            try MailStore.recomputeFiled(db, accountID: nil, messageIDs: nil)
        }
        return migrator
    }
}
