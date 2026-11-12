import Foundation

/// The parts of the Gmail v1 REST API that Dingo reads, as Codable values.
/// Google sends 64-bit integers (history IDs, internal dates) as JSON strings; these types turn
/// them into numbers and dates, and accept plain numbers too. Lists Gmail leaves out when empty
/// decode as empty arrays, so callers never unwrap them.
public enum GmailAPI {
    public struct Message: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var threadID: String
        public var labelIDs: [String]
        public var snippet: String
        public var historyID: UInt64?
        /// When Gmail received the message, which orders mail more reliably than the Date header.
        public var internalDate: Date?
        public var sizeEstimate: Int?
        /// The MIME tree for `full` and `metadata` formats. For `metadata` it holds only headers.
        public var payload: MessagePart?
        /// The whole message as base64url, for the `raw` format.
        public var raw: String?

        public init(id: String, threadID: String, labelIDs: [String] = [], snippet: String = "", historyID: UInt64? = nil,
                    internalDate: Date? = nil, sizeEstimate: Int? = nil, payload: MessagePart? = nil, raw: String? = nil) {
            self.id = id
            self.threadID = threadID
            self.labelIDs = labelIDs
            self.snippet = snippet
            self.historyID = historyID
            self.internalDate = internalDate
            self.sizeEstimate = sizeEstimate
            self.payload = payload
            self.raw = raw
        }

        enum CodingKeys: String, CodingKey {
            case id, threadID = "threadId", labelIDs = "labelIds", snippet, historyID = "historyId"
            case internalDate, sizeEstimate, payload, raw
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            threadID = try container.decodeIfPresent(String.self, forKey: .threadID) ?? ""
            labelIDs = try container.decodeIfPresent([String].self, forKey: .labelIDs) ?? []
            snippet = try container.decodeIfPresent(String.self, forKey: .snippet) ?? ""
            historyID = try container.decodeInt64String(.historyID)
            internalDate = try container.decodeInt64String(.internalDate).map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
            sizeEstimate = try container.decodeIfPresent(Int.self, forKey: .sizeEstimate)
            payload = try container.decodeIfPresent(MessagePart.self, forKey: .payload)
            raw = try container.decodeIfPresent(String.self, forKey: .raw)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(threadID, forKey: .threadID)
            try container.encode(labelIDs, forKey: .labelIDs)
            try container.encode(snippet, forKey: .snippet)
            try container.encodeIfPresent(historyID.map(String.init), forKey: .historyID)
            try container.encodeIfPresent(internalDate.map { String(Int64(($0.timeIntervalSince1970 * 1000).rounded())) }, forKey: .internalDate)
            try container.encodeIfPresent(sizeEstimate, forKey: .sizeEstimate)
            try container.encodeIfPresent(payload, forKey: .payload)
            try container.encodeIfPresent(raw, forKey: .raw)
        }
    }

    /// One node of a message's MIME tree. Multipart nodes have `parts`; leaves have a `body`.
    public struct MessagePart: Codable, Sendable, Equatable {
        public var partID: String?
        public var mimeType: String
        public var filename: String
        public var headers: [Header]
        public var body: MessagePartBody?
        public var parts: [MessagePart]?

        public init(partID: String? = nil, mimeType: String, filename: String = "", headers: [Header] = [],
                    body: MessagePartBody? = nil, parts: [MessagePart]? = nil) {
            self.partID = partID
            self.mimeType = mimeType
            self.filename = filename
            self.headers = headers
            self.body = body
            self.parts = parts
        }

        enum CodingKeys: String, CodingKey { case partID = "partId", mimeType, filename, headers, body, parts }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            partID = try container.decodeIfPresent(String.self, forKey: .partID)
            mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType) ?? ""
            filename = try container.decodeIfPresent(String.self, forKey: .filename) ?? ""
            headers = try container.decodeIfPresent([Header].self, forKey: .headers) ?? []
            body = try container.decodeIfPresent(MessagePartBody.self, forKey: .body)
            parts = try container.decodeIfPresent([MessagePart].self, forKey: .parts)
        }

        /// The first header with this name, compared case-insensitively. Values are raw, not RFC 2047 decoded.
        public func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    public struct Header: Codable, Sendable, Equatable {
        public var name: String
        public var value: String
        public init(name: String, value: String) { self.name = name; self.value = value }
    }

    /// A leaf's content. Small parts carry `data` inline; attachments carry an `attachmentID` to fetch.
    /// `data` is base64url of the transfer-decoded bytes, still in the part's declared charset.
    public struct MessagePartBody: Codable, Sendable, Equatable {
        public var attachmentID: String?
        public var size: Int
        public var data: String?

        public init(attachmentID: String? = nil, size: Int = 0, data: String? = nil) {
            self.attachmentID = attachmentID
            self.size = size
            self.data = data
        }

        enum CodingKeys: String, CodingKey { case attachmentID = "attachmentId", size, data }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            attachmentID = try container.decodeIfPresent(String.self, forKey: .attachmentID)
            size = try container.decodeIfPresent(Int.self, forKey: .size) ?? 0
            data = try container.decodeIfPresent(String.self, forKey: .data)
        }

        public var decodedData: Data? { data.flatMap(Data.init(base64URLEncoded:)) }
    }

    public struct Label: Codable, Sendable, Equatable, Identifiable {
        public struct Color: Codable, Sendable, Equatable {
            public var textColor: String?
            public var backgroundColor: String?
        }

        public var id: String
        public var name: String
        /// "system" for Gmail's own labels (INBOX, UNREAD), "user" for labels people and apps create.
        public var type: String?
        public var messageListVisibility: String?
        public var labelListVisibility: String?
        public var messagesTotal: Int?
        public var messagesUnread: Int?
        public var threadsTotal: Int?
        public var threadsUnread: Int?
        public var color: Color?

        public init(id: String, name: String, type: String? = nil) {
            self.id = id
            self.name = name
            self.type = type
        }
    }

    public struct ListMessagesResponse: Codable, Sendable, Equatable {
        /// Only `id` and `threadID` are filled in.
        public var messages: [Message]
        public var nextPageToken: String?
        public var resultSizeEstimate: Int?

        enum CodingKeys: String, CodingKey { case messages, nextPageToken, resultSizeEstimate }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            messages = try container.decodeIfPresent([Message].self, forKey: .messages) ?? []
            nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
            resultSizeEstimate = try container.decodeIfPresent(Int.self, forKey: .resultSizeEstimate)
        }
    }

    public struct Thread: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var snippet: String
        public var historyID: UInt64?
        public var messages: [Message]

        enum CodingKeys: String, CodingKey { case id, snippet, historyID = "historyId", messages }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            snippet = try container.decodeIfPresent(String.self, forKey: .snippet) ?? ""
            historyID = try container.decodeInt64String(.historyID)
            messages = try container.decodeIfPresent([Message].self, forKey: .messages) ?? []
        }
    }

    /// One change record from `history.list`. Messages inside carry only id, threadID, and labelIDs.
    public struct History: Codable, Sendable, Equatable, Identifiable {
        public struct MessageChange: Codable, Sendable, Equatable {
            public var message: Message
        }

        public struct LabelChange: Codable, Sendable, Equatable {
            public var message: Message
            public var labelIDs: [String]

            enum CodingKeys: String, CodingKey { case message, labelIDs = "labelIds" }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                message = try container.decode(Message.self, forKey: .message)
                labelIDs = try container.decodeIfPresent([String].self, forKey: .labelIDs) ?? []
            }
        }

        public var id: UInt64
        public var messages: [Message]
        public var messagesAdded: [MessageChange]
        public var messagesDeleted: [MessageChange]
        public var labelsAdded: [LabelChange]
        public var labelsRemoved: [LabelChange]

        enum CodingKeys: String, CodingKey { case id, messages, messagesAdded, messagesDeleted, labelsAdded, labelsRemoved }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeInt64String(.id) ?? 0
            messages = try container.decodeIfPresent([Message].self, forKey: .messages) ?? []
            messagesAdded = try container.decodeIfPresent([MessageChange].self, forKey: .messagesAdded) ?? []
            messagesDeleted = try container.decodeIfPresent([MessageChange].self, forKey: .messagesDeleted) ?? []
            labelsAdded = try container.decodeIfPresent([LabelChange].self, forKey: .labelsAdded) ?? []
            labelsRemoved = try container.decodeIfPresent([LabelChange].self, forKey: .labelsRemoved) ?? []
        }
    }

    public struct ListHistoryResponse: Codable, Sendable, Equatable {
        public var history: [History]
        public var nextPageToken: String?
        /// The mailbox's current history ID; store it as the next sync's starting point.
        public var historyID: UInt64

        enum CodingKeys: String, CodingKey { case history, nextPageToken, historyID = "historyId" }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            history = try container.decodeIfPresent([History].self, forKey: .history) ?? []
            nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
            historyID = try container.decodeInt64String(.historyID) ?? 0
        }
    }

    public struct Profile: Codable, Sendable, Equatable {
        public var emailAddress: String
        public var messagesTotal: Int
        public var threadsTotal: Int
        public var historyID: UInt64

        enum CodingKeys: String, CodingKey { case emailAddress, messagesTotal, threadsTotal, historyID = "historyId" }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            emailAddress = try container.decode(String.self, forKey: .emailAddress)
            messagesTotal = try container.decodeIfPresent(Int.self, forKey: .messagesTotal) ?? 0
            threadsTotal = try container.decodeIfPresent(Int.self, forKey: .threadsTotal) ?? 0
            historyID = try container.decodeInt64String(.historyID) ?? 0
        }
    }

    public struct Draft: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var message: Message?
    }

    struct ListLabelsResponse: Decodable {
        var labels: [Label]?
    }
}

private extension KeyedDecodingContainer {
    /// Google's int64 fields: a JSON string of digits, though a number is accepted too.
    func decodeInt64String(_ key: Key) throws -> UInt64? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let text = try? decode(String.self, forKey: key) {
            guard let value = UInt64(text) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Expected an integer string, got \(text)")
            }
            return value
        }
        return try decode(UInt64.self, forKey: key)
    }
}
