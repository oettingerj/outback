import Foundation
import GRDB

extension Bucket: DatabaseValueConvertible {}
extension ReceiptStatus: DatabaseValueConvertible {}
extension CalendarMethod: DatabaseValueConvertible {}
extension ParticipationStatus: DatabaseValueConvertible {}

/// A signed-in Gmail account. The address is the key every other row hangs off.
public struct MailAccount: Codable, Equatable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "account"

    public var email: String
    public var displayName: String?
    public var addedAt: Date
    /// Where incremental sync resumes (Gmail's `history.list` startHistoryId).
    public var historyID: UInt64?
    public var lastSyncAt: Date?
    /// The account's send-as aliases, so mail from any of them counts as the user's own.
    public var sendAs: [EmailAddress]
    /// Sidebar order.
    public var position: Int

    public var id: String { email }

    public init(email: String, displayName: String? = nil, addedAt: Date = Date(), historyID: UInt64? = nil,
                lastSyncAt: Date? = nil, sendAs: [EmailAddress] = [], position: Int = 0) {
        self.email = email
        self.displayName = displayName
        self.addedAt = addedAt
        self.historyID = historyID
        self.lastSyncAt = lastSyncAt
        self.sendAs = sendAs
        self.position = position
    }

    /// Lowercased addresses that are the user's: the account plus its aliases.
    public var addresses: Set<String> {
        Set([email.lowercased()] + sendAs.map { $0.email.lowercased() })
    }
}

/// A Gmail label. IDs are unique only within an account.
public struct MailLabel: Codable, Equatable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "label"

    public var accountID: String
    public var id: String
    public var name: String
    /// "system" or "user", as the Gmail API reports it.
    public var type: String

    public init(accountID: String, id: String, name: String, type: String) {
        self.accountID = accountID
        self.id = id
        self.name = name
        self.type = type
    }
}

/// One stored message: headers and flags the lists need, without the body.
public struct MailMessage: Codable, Equatable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "message"

    public enum BodyState: String, Codable, Sendable, DatabaseValueConvertible {
        /// Only metadata so far; fetch the full message before showing it.
        case none
        case fetched
    }

    public var accountID: String
    public var id: String
    public var threadID: String
    public var historyID: UInt64
    public var internalDate: Date
    public var fromName: String?
    public var fromEmail: String
    public var fromDomain: String
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var replyTo: String?
    public var subject: String
    public var snippet: String
    public var labelIDs: [String]
    public var bucket: Bucket
    public var isUnread: Bool
    public var isStarred: Bool
    public var isInInbox: Bool
    public var isTrashOrSpam: Bool
    /// In INBOX or carrying its bucket's `Dingo/*` label; archived mail is neither and leaves bucket
    /// views. Computed by the database from the labels (`MailStore.recomputeFiled`), so a value set
    /// here is overwritten on write.
    public var isFiled: Bool
    public var hasAttachments: Bool
    public var messageIDHeader: String?
    public var inReplyTo: String?
    public var references: String?
    public var listID: String?
    public var listUnsubscribe: String?
    public var listUnsubscribePost: String?
    /// What the notifications view groups by: "owner/repo" for GitHub, else the sender's domain.
    public var source: String
    public var bodyState: BodyState

    public var from: EmailAddress { EmailAddress(name: fromName, email: fromEmail) }

    enum CodingKeys: String, CodingKey {
        case accountID, id, threadID, historyID, internalDate, fromName, fromEmail, fromDomain
        case to = "toJSON", cc = "ccJSON", replyTo, subject, snippet, labelIDs = "labelIDsJSON", bucket
        case isUnread, isStarred, isInInbox, isTrashOrSpam, isFiled, hasAttachments, messageIDHeader, inReplyTo, references
        case listID, listUnsubscribe, listUnsubscribePost, source, bodyState
    }

    init(_ message: ParsedMessage, bucket: Bucket, bodyState: BodyState) {
        let from = message.from ?? EmailAddress(email: "")
        let headers = message.headers
        accountID = message.accountID
        id = message.id
        threadID = message.threadID
        historyID = message.historyID
        internalDate = message.internalDate
        fromName = from.name
        fromEmail = from.email.lowercased()
        fromDomain = from.domain
        to = message.to
        cc = message.cc
        replyTo = headers["Reply-To"]
        subject = message.subject
        snippet = message.snippet
        labelIDs = message.labelIDs
        self.bucket = bucket
        isUnread = false
        isStarred = false
        isInInbox = false
        isTrashOrSpam = false
        isFiled = false
        hasAttachments = !message.attachments.isEmpty
        messageIDHeader = headers["Message-ID"]
        inReplyTo = headers["In-Reply-To"]
        references = headers["References"]
        listID = headers["List-Id"]
        listUnsubscribe = headers["List-Unsubscribe"]
        listUnsubscribePost = headers["List-Unsubscribe-Post"]
        source = NotificationSource.key(listID: listID, fromDomain: fromDomain)
        self.bodyState = bodyState
        applyLabels(message.labelIDs)
    }

    /// Keeps the flag columns in step with the label list; they exist so views can filter on an index.
    mutating func applyLabels(_ labelIDs: [String]) {
        self.labelIDs = labelIDs
        let set = Set(labelIDs)
        isUnread = set.contains("UNREAD")
        isStarred = set.contains("STARRED")
        isInInbox = set.contains("INBOX")
        isTrashOrSpam = set.contains("TRASH") || set.contains("SPAM")
    }
}

/// A message's decoded body, stored apart from `message` so lists never load it.
public struct MailBody: Codable, Equatable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "messageBody"

    public struct InlinePart: Codable, Equatable, Sendable {
        public var mimeType: String
        public var attachmentID: String?
        /// The bytes when Gmail sent them inline (small images); stored base64 in the JSON column.
        public var data: Data?
    }

    public var accountID: String
    public var messageID: String
    public var html: String?
    public var text: String?
    public var calendar: String?
    /// Inline parts by Content-ID, for resolving cid: URLs in the HTML.
    public var inline: [String: InlinePart]

    public var id: String { messageID }

    enum CodingKeys: String, CodingKey {
        case accountID, messageID, html, text, calendar, inline = "inlineJSON"
    }

    init(accountID: String, messageID: String, body: ParsedMessage.Body) {
        self.accountID = accountID
        self.messageID = messageID
        html = body.html
        text = body.text
        calendar = body.calendar
        inline = body.inline.mapValues { InlinePart(mimeType: $0.mimeType, attachmentID: $0.attachmentID, data: $0.data) }
    }

    /// What full-text search indexes: the plain text part, or the HTML reduced to text.
    var searchText: String {
        if let text, !text.isEmpty { return text }
        return html.map(BodyText.plain(fromHTML:)) ?? ""
    }
}

/// A file attached to a message, in the order the message lists them. Gmail's attachment IDs change
/// between fetches, so rows are keyed by position and replaced whenever the message is saved.
public struct MailAttachment: Codable, Equatable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "attachment"

    public var accountID: String
    public var messageID: String
    public var position: Int
    public var attachmentID: String?
    public var filename: String
    public var mimeType: String
    public var size: Int

    public var id: String { "\(messageID)/\(position)" }
}

/// "Mail from this sender goes to this bucket", set when the user moves a message. `matcher` is a
/// lowercased address or `@domain`; a nil account applies to every account.
public struct SenderRule: Codable, Equatable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "senderRule"

    public var id: Int64?
    public var accountID: String?
    public var matcher: String
    public var bucket: Bucket
    public var createdAt: Date

    public init(id: Int64? = nil, accountID: String? = nil, matcher: String, bucket: Bucket, createdAt: Date = Date()) {
        self.id = id
        self.accountID = accountID
        self.matcher = Self.normalize(matcher)
        self.bucket = bucket
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public var isDomain: Bool { matcher.hasPrefix("@") }

    /// Lowercased, trimmed; a bare domain ("example.com") becomes "@example.com".
    public static func normalize(_ matcher: String) -> String {
        let trimmed = matcher.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.contains("@") ? trimmed : "@" + trimmed
    }
}

/// What the receipts view shows for a message in the Receipts bucket.
public struct Receipt: Codable, Equatable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "receipt"

    public var accountID: String
    public var messageID: String
    public var merchant: String?
    public var amount: Decimal?
    /// ISO 4217 code.
    public var currency: String?
    public var orderNumber: String?
    public var status: ReceiptStatus
    public var date: Date

    public var id: String { "\(accountID)/\(messageID)" }

    public init(accountID: String, messageID: String, merchant: String?, amount: Decimal?, currency: String?,
                orderNumber: String?, status: ReceiptStatus, date: Date) {
        self.accountID = accountID
        self.messageID = messageID
        self.merchant = merchant
        self.amount = amount
        self.currency = currency
        self.orderNumber = orderNumber
        self.status = status
        self.date = date
    }
}

/// The event an invitation message carries, flattened for the Invites view.
public struct CalendarEvent: Codable, Equatable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "calendarEvent"

    public var accountID: String
    public var messageID: String
    public var uid: String
    public var method: CalendarMethod
    public var sequence: Int
    public var summary: String?
    public var start: Date?
    public var end: Date?
    public var isAllDay: Bool
    public var timeZone: String?
    public var location: String?
    /// The DESCRIPTION, where invites put dial-ins and meeting links.
    public var notes: String?
    public var organizerName: String?
    public var organizerEmail: String?
    public var attendees: [CalendarAttendee]
    /// The user's own PARTSTAT when they have answered; nil while it needs action.
    public var myResponse: ParticipationStatus?
    public var url: String?

    public var id: String { "\(accountID)/\(messageID)" }

    enum CodingKeys: String, CodingKey {
        case accountID, messageID, uid, method, sequence, summary, start, end, isAllDay, timeZone, location, notes
        case organizerName, organizerEmail, attendees = "attendeesJSON", myResponse, url
    }

    init(accountID: String, messageID: String, method: CalendarMethod, event: CalendarInvite.Event, myAddresses: Set<String>) {
        self.accountID = accountID
        self.messageID = messageID
        uid = event.uid
        self.method = method
        sequence = event.sequence
        summary = event.summary
        start = event.start
        end = event.end
        isAllDay = event.isAllDay
        timeZone = event.timeZone
        location = event.location
        notes = event.description
        organizerName = event.organizer?.name
        organizerEmail = event.organizer?.email
        attendees = event.attendees
        url = event.url
        // In a REPLY the attendee line is the person answering, not the user.
        if method != .reply, let me = event.attendee(matching: myAddresses), me.status != .needsAction {
            myResponse = me.status
        }
    }

    /// Canceled by the organizer.
    public var isCanceled: Bool { method == .cancel }
}
