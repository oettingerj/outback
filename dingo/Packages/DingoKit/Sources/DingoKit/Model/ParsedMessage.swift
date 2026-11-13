import Foundation

/// A Gmail message decoded from the API's MIME tree into what Dingo reads, stores, and classifies.
/// The Gmail layer produces it (`GmailMessageDecoder`); persistence and the classifier consume it.
public struct ParsedMessage: Sendable, Equatable {
    public var accountID: String          // the account's Gmail address
    public var id: String                 // Gmail message ID
    public var threadID: String
    public var historyID: UInt64
    public var labelIDs: [String]
    public var internalDate: Date
    public var snippet: String
    public var headers: Headers
    /// Decoded body parts. Nil when only metadata was fetched.
    public var body: Body?
    public var attachments: [Attachment]

    public init(accountID: String, id: String, threadID: String, historyID: UInt64, labelIDs: [String],
                internalDate: Date, snippet: String, headers: Headers, body: Body? = nil, attachments: [Attachment] = []) {
        self.accountID = accountID
        self.id = id
        self.threadID = threadID
        self.historyID = historyID
        self.labelIDs = labelIDs
        self.internalDate = internalDate
        self.snippet = snippet
        self.headers = headers
        self.body = body
        self.attachments = attachments
    }

    public var from: EmailAddress? { headers.addresses("From").first }
    public var to: [EmailAddress] { headers.addresses("To") }
    public var cc: [EmailAddress] { headers.addresses("Cc") }
    public var subject: String { headers["Subject"] ?? "" }
    public var isUnread: Bool { labelIDs.contains("UNREAD") }
    public var isStarred: Bool { labelIDs.contains("STARRED") }
    public var isInInbox: Bool { labelIDs.contains("INBOX") }

    /// Header fields in message order with case-insensitive lookup. Values are already RFC 2047 decoded.
    public struct Headers: Sendable, Equatable {
        public var fields: [(name: String, value: String)]

        public init(_ fields: [(name: String, value: String)]) { self.fields = fields }

        public subscript(name: String) -> String? {
            fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        public func all(_ name: String) -> [String] {
            fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
        }

        public func contains(_ name: String) -> Bool { self[name] != nil }

        /// Mailboxes in an address header. Parsing lives with the MIME code (`AddressParser`).
        public func addresses(_ name: String) -> [EmailAddress] {
            all(name).flatMap(AddressParser.parse)
        }

        public static func == (lhs: Headers, rhs: Headers) -> Bool {
            lhs.fields.map(\.name) == rhs.fields.map(\.name) && lhs.fields.map(\.value) == rhs.fields.map(\.value)
        }
    }

    public struct Body: Sendable, Equatable {
        public var html: String?
        public var text: String?
        /// The raw text/calendar part, for invites.
        public var calendar: String?
        /// Inline images by Content-ID (without angle brackets), referenced from HTML as cid:.
        public var inline: [String: InlinePart]

        public init(html: String? = nil, text: String? = nil, calendar: String? = nil, inline: [String: InlinePart] = [:]) {
            self.html = html
            self.text = text
            self.calendar = calendar
            self.inline = inline
        }
    }

    public struct InlinePart: Sendable, Equatable {
        public var mimeType: String
        /// Present when the API returned the bytes inline; else fetch by `attachmentID`.
        public var data: Data?
        public var attachmentID: String?

        public init(mimeType: String, data: Data? = nil, attachmentID: String? = nil) {
            self.mimeType = mimeType
            self.data = data
            self.attachmentID = attachmentID
        }
    }

    public struct Attachment: Sendable, Equatable, Identifiable {
        public var id: String { attachmentID ?? filename }
        public var filename: String
        public var mimeType: String
        public var size: Int
        public var attachmentID: String?

        public init(filename: String, mimeType: String, size: Int, attachmentID: String?) {
            self.filename = filename
            self.mimeType = mimeType
            self.size = size
            self.attachmentID = attachmentID
        }
    }
}
