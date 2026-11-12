import Foundation
import Testing
@testable import DingoKit

@Suite struct GmailMessageDecoderTests {
    static func fixture(_ name: String) throws -> ParsedMessage {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/gmail"))
        let message = try JSONDecoder().decode(GmailAPI.Message.self, from: Data(contentsOf: url))
        return GmailMessageDecoder.decode(message, accountID: "me@example.com")
    }

    @Test func newsletter() throws {
        let message = try Self.fixture("newsletter")
        #expect(message.accountID == "me@example.com")
        #expect(message.id == "18c1f0a2b3c4d5e6")
        #expect(message.historyID == 9_876_543)
        #expect(message.internalDate == Date(timeIntervalSince1970: 1_731_312_000))
        #expect(message.isUnread && message.isInInbox)
        #expect(message.snippet == "Five things worth reading this week, from café culture to compilers & more. Don't miss")
        #expect(message.subject == "Issue 42: Café culture 🍕")
        #expect(message.from == EmailAddress(name: "The Weekly Dispatch", email: "news@dispatch.example"))
        #expect(message.headers["list-unsubscribe"] == "<https://dispatch.example/u/abc>, <mailto:unsubscribe@dispatch.example?subject=unsubscribe>")
        #expect(message.headers["List-Unsubscribe-Post"] == "List-Unsubscribe=One-Click")
        let body = try #require(message.body)
        #expect(body.html?.hasPrefix("<!doctype html>") == true)
        #expect(body.html?.contains("café culture") == true)
        #expect(body.text?.hasPrefix("The Weekly Dispatch\n") == true)
        #expect(body.calendar == nil)
        #expect(body.inline.isEmpty)
        #expect(message.attachments.isEmpty)
    }

    @Test func gitHubNotification() throws {
        let message = try Self.fixture("github")
        #expect(message.threadID == "18c1ffffffff0000")
        #expect(message.headers["X-GitHub-Reason"] == "review_requested")
        #expect(message.headers["X-GitHub-Sender"] == "ada")
        #expect(message.from?.name == "Ada Lovelace")
        #expect(message.cc == [EmailAddress(name: "Review requested", email: "review_requested@noreply.github.com")])
        #expect(message.headers.addresses("Reply-To").first?.email == "reply+ABC123@reply.github.com")
        // Folded headers arrive unfolded.
        #expect(message.headers["References"] == "<octo/widgets/pull/42@github.com> <octo/widgets/pull/42/c1@github.com>")
        #expect(message.body?.text?.contains("octo/widgets#42") == true)
        #expect(message.body?.html?.contains("<b>@ada</b>") == true)
    }

    @Test func calendarInviteWithInlineImage() throws {
        let message = try Self.fixture("invite")
        let body = try #require(message.body)
        #expect(body.calendar?.hasPrefix("BEGIN:VCALENDAR\r\n") == true)
        #expect(body.calendar?.contains("METHOD:REQUEST") == true)
        #expect(body.html?.contains("cid:logo@calendar.example") == true)
        #expect(body.text == "Design review\nFriday Nov 15 · 9:00 – 9:30am\n")
        let logo = try #require(body.inline["logo@calendar.example"])
        #expect(logo.mimeType == "image/png")
        #expect(logo.data?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        // The inline image isn't an attachment; the .ics file is.
        #expect(message.attachments == [
            ParsedMessage.Attachment(filename: "invite.ics", mimeType: "application/ics", size: 407, attachmentID: "ANGjdJ_ics_attachment"),
        ])
        #expect(message.headers.addresses("Reply-To") == [EmailAddress(name: "Grace Hopper", email: "grace@example.org")])
    }

    @Test func receiptWithAttachmentAndLegacyCharsets() throws {
        let message = try Self.fixture("receipt")
        #expect(message.subject == "Your receipt – €12,50")
        // The decoded name holds a comma; the header is rewritten so it still parses as one mailbox.
        #expect(message.headers["From"] == #""Café Lumière, Paris" <receipts@cafe.example>"#)
        #expect(message.from == EmailAddress(name: "Café Lumière, Paris", email: "receipts@cafe.example"))
        #expect(message.to == [EmailAddress(name: "Me, Myself", email: "me@example.com")])
        let body = try #require(message.body)
        #expect(body.text == "Café Lumière\nTotal: €12,50\nThank you!\n")
        // The list footer is a shallower sibling; the author's HTML is deeper and wins.
        #expect(body.html == "<p>Café Lumière</p><p>Total: €12,50</p>")
        #expect(message.attachments == [
            ParsedMessage.Attachment(filename: "Reçu-2041.pdf", mimeType: "application/pdf", size: 48213, attachmentID: "ANGjdJ_pdf_attachment"),
        ])
    }

    @Test func metadataOnlyHasNoBody() throws {
        let message = try Self.fixture("metadata")
        #expect(message.body == nil)
        #expect(message.attachments.isEmpty)
        #expect(message.subject == "Quick question")
        #expect(message.to == [EmailAddress(email: "me@example.com")])
    }

    @Test func singlePartPlainText() throws {
        let json = """
        {"id":"m1","threadId":"t1","historyId":12,"internalDate":"1000","payload":{"mimeType":"text/plain","filename":"",
         "headers":[{"name":"Content-Type","value":"text/plain; charset=iso-8859-1"}],
         "body":{"size":4,"data":"\(Data([0x63, 0x61, 0x66, 0xE9]).base64URLEncodedString())"}}}
        """
        let message = GmailMessageDecoder.decode(try JSONDecoder().decode(GmailAPI.Message.self, from: Data(json.utf8)), accountID: "a")
        #expect(message.body == ParsedMessage.Body(text: "café"))
        #expect(message.historyID == 12)
        #expect(message.internalDate == Date(timeIntervalSince1970: 1))
    }

    @Test func appleMailInlineFilesAreAttachmentsUnlessDrawn() throws {
        // Apple Mail sends every file with Content-Disposition: inline and a Content-ID. Only an
        // image the HTML draws is part of the body; the rest are attachments.
        func part(_ mimeType: String, _ filename: String, cid: String, id: String) -> String {
            """
            {"mimeType":"\(mimeType)","filename":"\(filename)","headers":[
             {"name":"Content-Disposition","value":"inline; filename=\\"\(filename)\\""},
             {"name":"Content-Id","value":"<\(cid)>"}],"body":{"size":10,"attachmentId":"\(id)"}}
            """
        }
        let html = Data(#"<p>Look</p><img src="cid:DRAWN-1">"#.utf8).base64URLEncodedString()
        let json = """
        {"id":"m1","threadId":"t1","historyId":1,"internalDate":"1000","payload":{"mimeType":"multipart/mixed","filename":"",
         "headers":[],"body":{"size":0},"parts":[
          {"mimeType":"text/html","filename":"","headers":[],"body":{"size":10,"data":"\(html)"}},
          \(part("image/jpeg", "drawn.jpeg", cid: "drawn-1", id: "a1")),
          \(part("image/jpeg", "IMG_0001.jpeg", cid: "photo-2", id: "a2")),
          \(part("application/pdf", "Lease.pdf", cid: "lease-3", id: "a3"))]}}
        """
        let message = GmailMessageDecoder.decode(try JSONDecoder().decode(GmailAPI.Message.self, from: Data(json.utf8)), accountID: "a")
        #expect(message.attachments.map(\.filename) == ["IMG_0001.jpeg", "Lease.pdf"])
        #expect(message.attachments.map(\.attachmentID) == ["a2", "a3"])
        #expect(Set(try #require(message.body).inline.keys) == ["drawn-1", "photo-2", "lease-3"])
    }

    @Test func messageRoundTripsThroughCodable() throws {
        let url = try #require(Bundle.module.url(forResource: "invite", withExtension: "json", subdirectory: "Fixtures/gmail"))
        let message = try JSONDecoder().decode(GmailAPI.Message.self, from: Data(contentsOf: url))
        let again = try JSONDecoder().decode(GmailAPI.Message.self, from: JSONEncoder().encode(message))
        #expect(again == message)
    }
}
