import Foundation
import Testing
@testable import DingoKit

@Suite struct MessageBuilderTests {
    /// A small MIME reader for checking the builder's output: headers unfolded and decoded, parts split on boundaries.
    struct Entity {
        var headers: [(String, String)]
        var body: String

        init(_ text: String) {
            let split = text.range(of: "\r\n\r\n")
            let head = split.map { String(text[..<$0.lowerBound]) } ?? text
            body = split.map { String(text[$0.upperBound...]) } ?? ""
            var fields: [(String, String)] = []
            for line in head.components(separatedBy: "\r\n") {
                if line.hasPrefix(" ") || line.hasPrefix("\t"), let last = fields.popLast() {
                    fields.append((last.0, last.1 + line))
                } else if let colon = line.firstIndex(of: ":") {
                    fields.append((String(line[..<colon]), String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
                }
            }
            headers = fields
        }

        subscript(_ name: String) -> String? { headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1 }

        var parts: [Entity] {
            guard let boundary = MIMEHeaderValue(self["Content-Type"] ?? "")["boundary"] else { return [] }
            let pieces = body.components(separatedBy: "--\(boundary)")
            #expect(pieces.last?.hasPrefix("--") == true)
            return pieces.dropFirst().dropLast().map { piece in
                var piece = piece
                if piece.hasPrefix("\r\n") { piece.removeFirst() }
                if piece.hasSuffix("\r\n") { piece.removeLast() }
                return Entity(piece)
            }
        }

        var decodedBody: String {
            switch self["Content-Transfer-Encoding"]?.lowercased() {
            case "quoted-printable": String(decoding: QuotedPrintable.decode(body), as: UTF8.self)
            case "base64": String(decoding: Data(base64Encoded: body, options: .ignoreUnknownCharacters) ?? Data(), as: UTF8.self)
            default: body
            }
        }
    }

    static let me = EmailAddress(name: "Zoë Dürr", email: "zoe@example.com")

    @Test func fullMessageParsesBack() throws {
        var builder = MessageBuilder(from: Self.me, to: [EmailAddress(name: "Lovelace, Ada", email: "ada@example.com")],
                                     cc: [EmailAddress(email: "grace@example.org")], bcc: [EmailAddress(email: "secret@example.net")],
                                     subject: "Café plans — Friday? " + String(repeating: "long ", count: 12),
                                     text: "Hi Ada,\nCafé at 9? = yes\n" + String(repeating: "x", count: 200),
                                     html: "<p>Hi Ada,</p><p>Café at 9?</p>",
                                     date: Date(timeIntervalSince1970: 1_731_312_000))
        builder.inReplyTo = "<parent@example.com>"
        builder.references = ["<root@example.com>", "<parent@example.com>"]
        builder.attachments = [MessageBuilder.Attachment(filename: "Reçu 2041.pdf", mimeType: "application/pdf", data: Data(repeating: 0xAB, count: 300))]
        builder.calendar = .init(ics: "BEGIN:VCALENDAR\nMETHOD:REPLY\nEND:VCALENDAR\n")

        let data = builder.build()
        let raw = String(decoding: data, as: UTF8.self)
        #expect(data.allSatisfy { $0 < 0x80 })
        #expect(!raw.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        #expect(!raw.replacingOccurrences(of: "\r\n", with: "").contains("\r"))
        for line in raw.components(separatedBy: "\r\n") { #expect(line.utf8.count <= 998) }

        let message = Entity(raw)
        #expect(AddressParser.parse(message["From"]!) == [Self.me])
        #expect(AddressParser.parse(message["To"]!) == [EmailAddress(name: "Lovelace, Ada", email: "ada@example.com")])
        #expect(message["Cc"] == "grace@example.org")
        #expect(message["Bcc"] == "secret@example.net")
        #expect(EncodedWord.decode(message["Subject"]!) == builder.subject)
        #expect(message["Message-ID"] == builder.messageID)
        #expect(message["Message-ID"]?.hasSuffix("@example.com>") == true)
        #expect(message["In-Reply-To"] == "<parent@example.com>")
        #expect(message["References"] == "<root@example.com> <parent@example.com>")
        #expect(message["MIME-Version"] == "1.0")
        #expect(message["Date"].flatMap(Self.parseDate) == builder.date)

        #expect(MIMEHeaderValue(message["Content-Type"]!).value == "multipart/mixed")
        let mixed = message.parts
        #expect(mixed.count == 2)
        let alternative = mixed[0]
        #expect(MIMEHeaderValue(alternative["Content-Type"]!).value == "multipart/alternative")
        let bodies = alternative.parts
        #expect(bodies.map { MIMEHeaderValue($0["Content-Type"]!).value } == ["text/plain", "text/html", "text/calendar"])
        #expect(bodies[0]["Content-Transfer-Encoding"] == "quoted-printable")
        #expect(bodies[0].body.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 76 })
        #expect(bodies[0].decodedBody == "Hi Ada,\r\nCafé at 9? = yes\r\n" + String(repeating: "x", count: 200))
        #expect(bodies[1].decodedBody == "<p>Hi Ada,</p><p>Café at 9?</p>")
        #expect(MIMEHeaderValue(bodies[2]["Content-Type"]!)["method"] == "REPLY")
        #expect(bodies[2].decodedBody == "BEGIN:VCALENDAR\r\nMETHOD:REPLY\r\nEND:VCALENDAR\r\n")

        let attachment = mixed[1]
        #expect(MIMEHeaderValue(attachment["Content-Disposition"]!)["filename"] == "Reçu 2041.pdf")
        #expect(MIMEHeaderValue(attachment["Content-Type"]!)["name"] == "Reçu 2041.pdf")
        #expect(attachment.body.components(separatedBy: "\r\n").allSatisfy { $0.count <= 76 })
        #expect(Data(base64Encoded: attachment.body, options: .ignoreUnknownCharacters) == Data(repeating: 0xAB, count: 300))

        #expect(Data(base64URLEncoded: builder.base64URLEncoded())?.count == data.count)
    }

    @Test func textOnlyIsSinglePart() {
        let raw = String(decoding: MessageBuilder(from: EmailAddress(email: "me@example.com"), to: [EmailAddress(email: "a@example.com")],
                                                  subject: "Hello", text: "Just text").build(), as: UTF8.self)
        let message = Entity(raw)
        #expect(message["Subject"] == "Hello")
        #expect(message["Content-Type"] == "text/plain; charset=utf-8")
        #expect(message.decodedBody == "Just text\r\n")
    }

    @Test func replySubjectsDoNotStack() {
        #expect(Reply.subject("Lunch") == "Re: Lunch")
        #expect(Reply.subject("Re: Lunch") == "Re: Lunch")
        #expect(Reply.subject("RE: Lunch") == "RE: Lunch")
        #expect(Reply.subject("Re[2]: Lunch") == "Re[2]: Lunch")
        #expect(Reply.subject("Fwd: Lunch") == "Re: Fwd: Lunch")
        #expect(Reply.forwardSubject("Lunch") == "Fwd: Lunch")
        #expect(Reply.forwardSubject("FW: Lunch") == "FW: Lunch")
        #expect(Reply.forwardSubject("Re: Lunch") == "Fwd: Re: Lunch")
    }

    static func message(_ headers: [(String, String)]) -> ParsedMessage {
        ParsedMessage(accountID: "me@example.com", id: "m", threadID: "t", historyID: 1, labelIDs: [], internalDate: Date(),
                      snippet: "", headers: ParsedMessage.Headers(headers.map { (name: $0.0, value: $0.1) }))
    }

    @Test func replyAllRecipients() {
        let original = Self.message([
            ("From", "Ada <ada@example.com>"),
            ("To", "Me <ME@example.com>, Grace <grace@example.org>"),
            ("Cc", "alan@example.net, me+alias@example.com, ada@example.com"),
            ("Subject", "Plans"),
            ("Message-ID", "<m2@example.com>"),
            ("References", "<m0@example.com> <m1@example.com>"),
        ])
        let own: Set<String> = ["me@example.com", "me+alias@example.com"]
        let all = Reply.recipients(original, all: true, ownAddresses: own)
        #expect(all.to.map(\.email) == ["ada@example.com", "grace@example.org"])
        #expect(all.cc.map(\.email) == ["alan@example.net"])
        #expect(Reply.recipients(original, all: false, ownAddresses: own).to.map(\.email) == ["ada@example.com"])

        let builder = MessageBuilder.reply(to: original, from: EmailAddress(email: "me@example.com"), all: true, ownAddresses: own)
        #expect(builder.subject == "Re: Plans")
        #expect(builder.inReplyTo == "<m2@example.com>")
        #expect(builder.references == ["<m0@example.com>", "<m1@example.com>", "<m2@example.com>"])
        #expect(builder.cc.map(\.email) == ["alan@example.net"])
    }

    @Test func replyHonorsReplyToAndOwnMessages() {
        let list = Self.message([("From", "Ada <ada@example.com>"), ("Reply-To", "list@example.com"), ("To", "list@example.com")])
        #expect(Reply.recipients(list, all: true, ownAddresses: ["me@example.com"]).to.map(\.email) == ["list@example.com"])

        let sent = Self.message([("From", "me@example.com"), ("To", "ada@example.com"), ("Cc", "grace@example.org")])
        let reply = Reply.recipients(sent, all: true, ownAddresses: ["me@example.com"])
        #expect(reply.to.map(\.email) == ["ada@example.com"])
        #expect(reply.cc.map(\.email) == ["grace@example.org"])

        let onlyCc = Self.message([("From", "me@example.com"), ("Cc", "grace@example.org")])
        #expect(Reply.recipients(onlyCc, all: true, ownAddresses: ["me@example.com"]).to.map(\.email) == ["grace@example.org"])
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.date(from: text)
    }
}
