import Foundation
import Testing
@testable import DingoKit

/// Builds `ParsedMessage` values for the bucket, store, and parser tests.
enum BucketFixtures {
    static let me = "me@example.org"
    static let baseDate = Date(timeIntervalSince1970: 1_794_000_000) // 2026-11-07

    static func message(id: String = UUID().uuidString, account: String = me, thread: String? = nil, from: String,
                        subject: String, labels: [String] = ["INBOX", "UNREAD"], headers: [(String, String)] = [],
                        date: Date = baseDate, snippet: String = "", html: String? = nil, text: String? = nil,
                        calendar: String? = nil, attachments: [ParsedMessage.Attachment] = []) -> ParsedMessage {
        let fields = [("From", from), ("To", account), ("Subject", subject)] + headers
        let body = html == nil && text == nil && calendar == nil ? nil : ParsedMessage.Body(html: html, text: text, calendar: calendar)
        return ParsedMessage(accountID: account, id: id, threadID: thread ?? id, historyID: 1, labelIDs: labels,
                             internalDate: date, snippet: snippet, headers: .init(fields.map { (name: $0.0, value: $0.1) }),
                             body: body, attachments: attachments)
    }

    static func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/buckets"))
        return try String(contentsOf: url, encoding: .utf8)
    }
}

struct ClassifierCase: Sendable, CustomTestStringConvertible {
    var name: String
    var message: ParsedMessage
    var expected: Bucket
    var testDescription: String { name }
}

@Suite struct ClassifierTests {
    typealias F = BucketFixtures

    static let invite = """
        BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:abc@google.com\r\nDTSTART:20261118T170000Z\r\nSUMMARY:Sync\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n
        """
    static let reply = invite.replacingOccurrences(of: "METHOD:REQUEST", with: "METHOD:REPLY")
    static let jsonLD = #"<script type="application/ld+json">{"@context":"http://schema.org","@type":"Order","orderNumber":"1001"}</script>"#
    static let github: [(String, String)] = [
        ("List-Id", "dingo/dingo <dingo.dingo.github.com>"),
        ("List-Unsubscribe", "<mailto:unsub+abc@reply.github.com>, <https://github.com/notifications/unsubscribe/abc>"),
        ("X-GitHub-Reason", "review_requested"),
        ("Precedence", "list"),
    ]

    static let cases: [ClassifierCase] = [
        // Inbox: people, and what the user wrote.
        ClassifierCase(name: "human mentioning a receipt", message: F.message(
            from: "Sam Park <sam.park@gmail.com>", subject: "Did you get the receipt for dinner?",
            labels: ["INBOX", "CATEGORY_PERSONAL"]), expected: .inbox),
        ClassifierCase(name: "human mentioning an invoice, no category", message: F.message(
            from: "Sam Park <sam.park@gmail.com>", subject: "Invoice question"), expected: .inbox),
        ClassifierCase(name: "sent mail", message: F.message(
            from: "Me <me@example.org>", subject: "Your order of cupcakes", labels: ["SENT"]), expected: .inbox),
        ClassifierCase(name: "draft", message: F.message(
            from: "Me <me@example.org>", subject: "Receipt", labels: ["DRAFT"],
            headers: [("List-Unsubscribe", "<mailto:x@example.com>")]), expected: .inbox),
        ClassifierCase(name: "plain human mail", message: F.message(
            from: "Ada Lovelace <ada@example.com>", subject: "Lunch Thursday?"), expected: .inbox),

        // Invites.
        ClassifierCase(name: "Google Calendar invite with calendar part", message: F.message(
            from: "Ada Lovelace <ada@example.com>", subject: "Invitation: Sync @ Wed Nov 18, 2026 9am - 9:30am (PST)",
            labels: ["INBOX", "CATEGORY_PERSONAL"], headers: [("Sender", "Google Calendar <calendar-notification@google.com>")],
            calendar: invite), expected: .calendar),
        ClassifierCase(name: "Google Calendar invite, metadata only", message: F.message(
            from: "Ada Lovelace <ada@example.com>", subject: "Updated invitation: Sync @ Wed Nov 18, 2026",
            labels: ["INBOX", "CATEGORY_PERSONAL"], headers: [("Sender", "Google Calendar <calendar-notification@google.com>")]),
            expected: .calendar),
        ClassifierCase(name: "canceled event from calendar-notification", message: F.message(
            from: "Google Calendar <calendar-notification@google.com>", subject: "Canceled event: Sync"), expected: .calendar),
        ClassifierCase(name: "attendee reply", message: F.message(
            from: "Grace Hopper <grace@contoso.com>", subject: "Accepted: Sync", calendar: reply), expected: .calendar),
        ClassifierCase(name: "calendar part beats receipt markup", message: F.message(
            from: "Airline <noreply@airline.example>", subject: "Your flight confirmation",
            html: #"<script type="application/ld+json">{"@type":"FlightReservation"}</script>"#, calendar: invite), expected: .calendar),

        // Receipts.
        ClassifierCase(name: "Amazon order", message: F.message(
            from: "\"Amazon.com\" <auto-confirm@amazon.com>", subject: "Your Amazon.com order of \"USB-C cable\"",
            labels: ["INBOX", "CATEGORY_UPDATES"]), expected: .receipts),
        ClassifierCase(name: "Amazon shipment with Auto-Submitted", message: F.message(
            from: "Amazon.com <shipment-tracking@amazon.com>", subject: "Shipped: \"USB-C cable\"",
            headers: [("Auto-Submitted", "auto-generated")]), expected: .receipts),
        ClassifierCase(name: "Stripe invoice", message: F.message(
            from: "\"Acme, Inc.\" <invoice+statements+acct_1AbC@stripe.com>", subject: "Your invoice from Acme, Inc. #INV-0042"),
            expected: .receipts),
        ClassifierCase(name: "Apple receipt", message: F.message(
            from: "Apple <no_reply@email.apple.com>", subject: "Your receipt from Apple."), expected: .receipts),
        ClassifierCase(name: "Uber trip", message: F.message(
            from: "Uber Receipts <noreply@uber.com>", subject: "Your Thursday evening trip with Uber"), expected: .receipts),
        ClassifierCase(name: "JSON-LD order from a shop", message: F.message(
            from: "Tiny Shop <hello@tinyshop.example>", subject: "Thanks!", html: jsonLD), expected: .receipts),
        ClassifierCase(name: "Shopify-style confirmation in Updates", message: F.message(
            from: "Tiny Shop <store@tinyshop.example>", subject: "Order #1001 confirmed",
            labels: ["INBOX", "CATEGORY_UPDATES"]), expected: .receipts),
        ClassifierCase(name: "billing@ sender", message: F.message(
            from: "Fastmail <billing@fastmail.example>", subject: "Payment for November"), expected: .receipts),

        // Notifications.
        ClassifierCase(name: "GitHub with List-Unsubscribe", message: F.message(
            from: "Octo Cat <notifications@github.com>", subject: "Re: [dingo/dingo] Fix invoice rounding (PR #12)",
            headers: github), expected: .notifications),
        ClassifierCase(name: "GitHub list without X-GitHub-Reason", message: F.message(
            from: "Octo Cat <notifications@github.com>", subject: "[dingo/dingo] Release 1.0",
            headers: [("List-Id", "dingo/dingo <dingo.dingo.github.com>"), ("List-Unsubscribe", "<mailto:u@github.com>")]),
            expected: .notifications),
        ClassifierCase(name: "Linear", message: F.message(
            from: "Linear <notifications@linear.app>", subject: "DIN-42 assigned to you",
            headers: [("List-Unsubscribe", "<https://linear.app/unsubscribe>")]), expected: .notifications),
        ClassifierCase(name: "Sentry alert", message: F.message(
            from: "Sentry <alerts@sentry.io>", subject: "New issue: TypeError in sync",
            headers: [("List-Unsubscribe", "<https://sentry.io/unsubscribe>")]), expected: .notifications),
        ClassifierCase(name: "password reset", message: F.message(
            from: "Example <no-reply@accounts.example.com>", subject: "Reset your password"), expected: .notifications),
        ClassifierCase(name: "Google security alert", message: F.message(
            from: "Google <no-reply@accounts.google.com>", subject: "Security alert", labels: ["INBOX", "CATEGORY_UPDATES"]),
            expected: .notifications),
        ClassifierCase(name: "Auto-Submitted", message: F.message(
            from: "Ops <ops@company.example>", subject: "Nightly backup finished", headers: [("Auto-Submitted", "auto-generated")]),
            expected: .notifications),
        ClassifierCase(name: "Updates without unsubscribe", message: F.message(
            from: "Bank <team@bank.example>", subject: "Your statement is ready", labels: ["INBOX", "CATEGORY_UPDATES"]),
            expected: .notifications),
        ClassifierCase(name: "Apple sign-in notice, not a receipt", message: F.message(
            from: "Apple <no_reply@email.apple.com>", subject: "Your Apple Account was used to sign in"), expected: .notifications),

        // Newsletters.
        ClassifierCase(name: "Substack issue on a custom domain", message: F.message(
            from: "Platformer <casey@platformer.news>", subject: "The week in platforms",
            headers: [("List-Id", "<platformer.substack.com>"), ("List-Unsubscribe", "<https://platformer.substack.com/action/disable_email>")]),
            expected: .newsletters),
        ClassifierCase(name: "Substack issue on substack.com", message: F.message(
            from: "Sinocism <sinocism@substack.com>", subject: "Weekly roundup"), expected: .newsletters),
        ClassifierCase(name: "Medium digest", message: F.message(
            from: "Medium Daily Digest <noreply@medium.com>", subject: "Swift concurrency in practice"), expected: .newsletters),
        ClassifierCase(name: "Mailchimp campaign", message: F.message(
            from: "Local Bakery <hello@bakery.example>", subject: "November news",
            headers: [("List-Unsubscribe", "<https://bakery.us1.list-manage.com/unsubscribe?u=1>")]), expected: .newsletters),
        ClassifierCase(name: "marketing \"order now\" is not a receipt", message: F.message(
            from: "Store <news@store.example>", subject: "Pre-order now: new headphones, 20% off",
            labels: ["INBOX", "CATEGORY_PROMOTIONS"], headers: [("List-Unsubscribe", "<mailto:unsub@store.example>")]),
            expected: .newsletters),
        ClassifierCase(name: "Amazon marketing", message: F.message(
            from: "Amazon.com <store-news@amazon.com>", subject: "Deals picked for you",
            headers: [("List-Unsubscribe", "<https://amazon.com/unsub>")]), expected: .newsletters),
        ClassifierCase(name: "mailing list with Precedence: list", message: F.message(
            from: "Jo Writer <jo@example.net>", subject: "[swift-dev] Proposal review",
            labels: ["INBOX", "CATEGORY_FORUMS"], headers: [("List-Id", "<swift-dev.forums.example>"), ("Precedence", "list")]),
            expected: .newsletters),
        ClassifierCase(name: "personal category with List-Unsubscribe", message: F.message(
            from: "Jo Writer <jo@example.net>", subject: "My monthly letter", labels: ["INBOX", "CATEGORY_PERSONAL"],
            headers: [("List-Unsubscribe", "<mailto:leave@example.net>")]), expected: .newsletters),
    ]

    @Test(arguments: cases)
    func classifies(_ testCase: ClassifierCase) {
        let result = Classifier(rules: .empty).classification(testCase.message)
        #expect(result.bucket == testCase.expected, "\(testCase.name): \(result.reason)")
    }

    @Test func caseCount() {
        #expect(Self.cases.count >= 25)
        #expect(Set(Self.cases.map(\.expected)) == Set(Bucket.allCases))
    }

    // MARK: - Precedence boundaries

    @Test func dingoLabelFromAnotherDeviceWins() {
        let message = F.message(from: "Platformer <casey@platformer.news>", subject: "Weekly",
                                labels: ["Label_7", "UNREAD"], headers: [("List-Unsubscribe", "<mailto:u@x.example>")])
        let classifier = Classifier(rules: .empty, labelNames: ["Label_7": "Dingo/Receipts", "Label_8": "Travel"])
        #expect(classifier.classification(message) == .init(bucket: .receipts, reason: "Dingo label"))
    }

    @Test func dingoLabelBeatsCalendarPart() {
        let message = F.message(from: "Ada <ada@example.com>", subject: "Invitation: Sync", labels: ["Label_9"], calendar: Self.invite)
        #expect(Classifier(rules: .empty, labelNames: ["Label_9": "Dingo/Notifications"]).classify(message) == .notifications)
    }

    @Test func senderRuleBeatsDingoLabel() {
        let rules = SenderRuleLookup([SenderRule(matcher: "@platformer.news", bucket: .inbox)])
        let message = F.message(from: "Platformer <casey@platformer.news>", subject: "Weekly", labels: ["Label_7"])
        let result = Classifier(rules: rules, labelNames: ["Label_7": "Dingo/Newsletters"]).classification(message)
        #expect(result == .init(bucket: .inbox, reason: "sender rule @platformer.news"))
    }

    @Test func sentMailBeatsSenderRule() {
        let rules = SenderRuleLookup([SenderRule(matcher: "@example.org", bucket: .notifications)])
        let message = F.message(from: "Me <me@example.org>", subject: "Hi", labels: ["SENT"])
        #expect(Classifier(rules: rules).classify(message) == .inbox)
    }

    @Test func senderRuleBeatsEverySignal() {
        let rules = SenderRuleLookup([SenderRule(matcher: "notifications@github.com", bucket: .newsletters)])
        let message = F.message(from: "<notifications@github.com>", subject: "[dingo/dingo] x", headers: Self.github)
        #expect(Classifier(rules: rules).classify(message) == .newsletters)
    }

    @Test func exactAddressBeatsDomain() {
        let rules = SenderRuleLookup([
            SenderRule(matcher: "@example.com", bucket: .notifications),
            SenderRule(matcher: "ceo@example.com", bucket: .inbox),
        ])
        #expect(rules.rule(for: EmailAddress(email: "CEO@Example.com"), accountID: F.me)?.bucket == .inbox)
        #expect(rules.rule(for: EmailAddress(email: "bot@example.com"), accountID: F.me)?.bucket == .notifications)
        #expect(rules.rule(for: EmailAddress(email: "bot@mail.example.com"), accountID: F.me)?.bucket == .notifications)
        #expect(rules.rule(for: EmailAddress(email: "bot@other.com"), accountID: F.me) == nil)
    }

    @Test func accountRuleBeatsGlobal() {
        let rules = SenderRuleLookup([
            SenderRule(accountID: nil, matcher: "@shop.example", bucket: .newsletters),
            SenderRule(accountID: "work@example.org", matcher: "@shop.example", bucket: .receipts),
        ])
        let address = EmailAddress(email: "news@shop.example")
        #expect(rules.rule(for: address, accountID: "work@example.org")?.bucket == .receipts)
        #expect(rules.rule(for: address, accountID: F.me)?.bucket == .newsletters)
    }

    @Test func exactGlobalBeatsAccountDomain() {
        let rules = SenderRuleLookup([
            SenderRule(accountID: F.me, matcher: "@shop.example", bucket: .newsletters),
            SenderRule(accountID: nil, matcher: "orders@shop.example", bucket: .receipts),
        ])
        #expect(rules.rule(for: EmailAddress(email: "orders@shop.example"), accountID: F.me)?.bucket == .receipts)
    }

    @Test func personalGuardStopsWeakReceiptWording() {
        let message = F.message(from: "Store Owner <owner@tinyshop.example>", subject: "Your order is ready for pickup",
                                labels: ["INBOX", "CATEGORY_PERSONAL"])
        #expect(Classifier(rules: .empty).classification(message).reason == "personal mail from a person")
    }

    @Test func definiteReceiptBeatsPersonalGuard() {
        let message = F.message(from: "Store Owner <owner@tinyshop.example>", subject: "Thanks",
                                labels: ["INBOX", "CATEGORY_PERSONAL"], html: Self.jsonLD)
        #expect(Classifier(rules: .empty).classify(message) == .receipts)
    }

    @Test func rulesAreCheckedInBucketOrder() {
        // Receipt wording beats the generic automated-sender notification rule.
        let message = F.message(from: "Shop <no-reply@shop.example>", subject: "Your order has shipped")
        #expect(Classifier(rules: .empty).classification(message) == .init(bucket: .receipts, reason: "receipt wording"))
    }
}
