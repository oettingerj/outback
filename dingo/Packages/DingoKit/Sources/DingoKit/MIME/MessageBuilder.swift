import Foundation

/// Composes an RFC 5322 message for `GmailClient.send(raw:)` and drafts. Bodies go out as UTF-8
/// quoted-printable, text and HTML together as multipart/alternative, wrapped in multipart/mixed
/// when there are attachments. Lines end in CRLF and headers fold at 78 characters.
public struct MessageBuilder: Sendable {
    public struct Attachment: Sendable, Equatable {
        public var filename: String
        public var mimeType: String
        public var data: Data

        public init(filename: String, mimeType: String, data: Data) {
            self.filename = filename
            self.mimeType = mimeType
            self.data = data
        }
    }

    /// An iCalendar object sent with the message, such as an iMIP RSVP (`method` REPLY).
    public struct CalendarPart: Sendable, Equatable {
        public var ics: String
        public var method: String

        public init(ics: String, method: String = "REPLY") {
            self.ics = ics
            self.method = method
        }
    }

    public var from: EmailAddress
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    /// Gmail delivers to Bcc recipients and strips the header before sending.
    public var bcc: [EmailAddress]
    public var subject: String
    public var date: Date
    /// With angle brackets, as it appears in the header: "<id@example.com>".
    public var messageID: String
    public var inReplyTo: String?
    public var references: [String]
    public var text: String?
    public var html: String?
    public var calendar: CalendarPart?
    public var attachments: [Attachment]

    public init(from: EmailAddress, to: [EmailAddress] = [], cc: [EmailAddress] = [], bcc: [EmailAddress] = [],
                subject: String = "", text: String? = nil, html: String? = nil, date: Date = Date()) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.date = date
        let domain = from.domain.isEmpty ? "dingo.local" : from.domain
        self.messageID = "<\(UUID().uuidString.lowercased())@\(domain)>"
        self.inReplyTo = nil
        self.references = []
        self.text = text
        self.html = html
        self.calendar = nil
        self.attachments = []
    }

    /// The message as bytes, ASCII only, with CRLF line endings.
    public func build() -> Data {
        var headers: [(String, String)] = [("From", from.headerValue)]
        if !to.isEmpty { headers.append(("To", Self.addressList(to))) }
        if !cc.isEmpty { headers.append(("Cc", Self.addressList(cc))) }
        if !bcc.isEmpty { headers.append(("Bcc", Self.addressList(bcc))) }
        headers.append(("Subject", EncodedWord.encode(subject)))
        headers.append(("Date", Self.dateString(date)))
        headers.append(("Message-ID", messageID))
        if let inReplyTo { headers.append(("In-Reply-To", inReplyTo)) }
        if !references.isEmpty { headers.append(("References", references.joined(separator: " "))) }
        headers.append(("MIME-Version", "1.0"))
        let body = bodyEntity()
        let message = Entity(headers: headers + body.headers, content: body.content)
        return Data((message.rendered + "\r\n").utf8)
    }

    /// `build()` as base64url, for APIs that take the message inside JSON.
    public func base64URLEncoded() -> String { build().base64URLEncodedString() }

    // MARK: Entities

    private struct Entity {
        var headers: [(String, String)]
        var content: String

        var rendered: String {
            headers.map { MessageBuilder.fold($0.0, $0.1) }.joined(separator: "\r\n") + "\r\n\r\n" + content
        }
    }

    private func bodyEntity() -> Entity {
        var alternatives: [Entity] = []
        if let text { alternatives.append(Self.textEntity(text, subtype: "plain")) }
        if let html { alternatives.append(Self.textEntity(html, subtype: "html")) }
        if let calendar { alternatives.append(Self.calendarEntity(calendar)) }
        if alternatives.isEmpty { alternatives.append(Self.textEntity("", subtype: "plain")) }
        let main = alternatives.count == 1 ? alternatives[0] : Self.multipart("alternative", alternatives)
        guard !attachments.isEmpty else { return main }
        return Self.multipart("mixed", [main] + attachments.map(Self.attachmentEntity))
    }

    private static func textEntity(_ text: String, subtype: String) -> Entity {
        Entity(headers: [("Content-Type", "text/\(subtype); charset=utf-8"), ("Content-Transfer-Encoding", "quoted-printable")],
               content: QuotedPrintable.encode(text))
    }

    /// Plain 7bit when the calendar is ASCII, as invites usually are, so any client reads it; base64 otherwise.
    private static func calendarEntity(_ calendar: CalendarPart) -> Entity {
        let ics = calendar.ics.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        let type = ("Content-Type", "text/calendar; charset=utf-8; method=\(calendar.method)")
        if ics.allSatisfy(\.isASCII), !ics.components(separatedBy: "\r\n").contains(where: { $0.utf8.count > 998 }) {
            return Entity(headers: [type, ("Content-Transfer-Encoding", "7bit")], content: ics)
        }
        return Entity(headers: [type, ("Content-Transfer-Encoding", "base64")], content: base64Lines(Data(ics.utf8)))
    }

    private static func attachmentEntity(_ attachment: Attachment) -> Entity {
        // Older clients read the RFC 2047 name on Content-Type; newer ones the RFC 2231 filename.
        let name = EncodedWord.needsEncoding(attachment.filename)
            ? "name=\"\(EncodedWord.encode(attachment.filename))\""
            : MIMEHeaderValue.parameter("name", attachment.filename)
        return Entity(headers: [
            ("Content-Type", "\(attachment.mimeType); \(name)"),
            ("Content-Disposition", "attachment; \(MIMEHeaderValue.parameter("filename", attachment.filename))"),
            ("Content-Transfer-Encoding", "base64"),
        ], content: base64Lines(attachment.data))
    }

    private static func multipart(_ subtype: String, _ parts: [Entity]) -> Entity {
        let boundary = "dingo-\(UUID().uuidString)"
        let content = parts.map { "--\(boundary)\r\n\($0.rendered)\r\n" }.joined() + "--\(boundary)--"
        return Entity(headers: [("Content-Type", "multipart/\(subtype); boundary=\"\(boundary)\"")], content: content)
    }

    private static func base64Lines(_ data: Data) -> String {
        data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }

    // MARK: Headers

    private static func addressList(_ addresses: [EmailAddress]) -> String {
        addresses.map(\.headerValue).joined(separator: ", ")
    }

    /// "Name: value", folded at spaces so lines stay within 78 characters where the value allows.
    /// The first word stays on the header's line, so the value never starts with folding whitespace.
    static func fold(_ name: String, _ value: String) -> String {
        let line = "\(name): \(value)"
        guard line.count > 78 else { return line }
        var output = ""
        var current = ""
        for word in line.split(separator: " ", omittingEmptySubsequences: false) {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count > 78, current != "\(name):" {
                output += current + "\r\n"
                current = " " + word
            } else {
                current += " " + word
            }
        }
        return output + current
    }

    static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}
