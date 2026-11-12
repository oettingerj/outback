#if DEBUG
import AppKit
import DingoKit

/// Debug only: synthetic mail in every bucket, for designing and reviewing the views without a
/// Google sign-in. Everything here is made up; the account is `sample@dingo.test`, which Gmail
/// calls fail for, so actions on it show their error state.
@MainActor
enum SampleMail {
    static let account = "sample@dingo.test"

    static func seedIfRequested() {
        guard ProcessInfo.processInfo.environment["DINGO_SAMPLE_MAIL"] == "1" else { return }
        Task { await seed() }
    }

    static func seed() async {
        let store = AppServices.shared.store
        try? await store.upsert(MailAccount(email: account, displayName: "Josh", sendAs: [EmailAddress(name: "Josh", email: account)]))
        let labels = Bucket.sorted.compactMap { bucket in bucket.labelName.map { MailLabel(accountID: account, id: "Label_\(bucket.rawValue)", name: $0, type: "user") } }
        try? await store.replaceLabels(labels + [MailLabel(accountID: account, id: "INBOX", name: "INBOX", type: "system")], accountID: account)
        let messages = people() + newsletters() + notifications() + receipts() + invites()
        let classifier = (try? await store.classifier(accountID: account)) ?? Classifier(rules: SenderRuleLookup([]))
        await save(messages, to: store, classifier: classifier)
        // As if mirrored: sorted mail carries its label and has left the Inbox.
        let saved = (try? await store.messages(accountID: account, ids: messages.map(\.id))) ?? []
        var changes: [String: (add: [String], remove: [String])] = [:]
        for message in saved where message.bucket != .inbox {
            changes[message.id] = (add: ["Label_\(message.bucket.rawValue)"], remove: ["INBOX"])
        }
        _ = try? await store.setLabels(accountID: account, changes: changes)
    }

    /// Off the main actor, where the store's bucket closure runs.
    nonisolated private static func save(_ messages: [ParsedMessage], to store: MailStore, classifier: Classifier) async {
        try? await store.save(messages) { classifier.classify($0) }
    }

    // MARK: Builders

    private static var counter = 0

    private static func message(from: String, subject: String, snippet: String, hoursAgo: Double, labels: [String] = ["INBOX"],
                                unread: Bool = true, headers extra: [(String, String)] = [], html: String? = nil, text: String? = nil,
                                calendar: String? = nil, to: String = "Josh <sample@dingo.test>", thread: String? = nil) -> ParsedMessage {
        counter += 1
        let id = String(format: "sample%04d", counter)
        var fields: [(name: String, value: String)] = [("From", from), ("To", to), ("Subject", subject),
                                                       ("Message-ID", "<\(id)@dingo.test>")]
        fields += extra.map { (name: $0.0, value: $0.1) }
        return ParsedMessage(accountID: account, id: id, threadID: thread ?? id, historyID: UInt64(counter),
                             labelIDs: labels + (unread ? ["UNREAD"] : []),
                             internalDate: Date().addingTimeInterval(-hoursAgo * 3600), snippet: snippet,
                             headers: .init(fields), body: .init(html: html, text: text ?? snippet, calendar: calendar))
    }

    private static func people() -> [ParsedMessage] {
        [
            message(from: "Maya Chen <maya@example.com>", subject: "Friday walkthrough of the sync rewrite",
                    snippet: "I pushed the branch. Mostly want eyes on the history-expired path before we merge.", hoursAgo: 0.4,
                    labels: ["INBOX", "CATEGORY_PERSONAL"],
                    text: "Hey Josh,\n\nI pushed the branch. Mostly want eyes on the history-expired path before we merge — it falls back to a full sync and I'm not sure the window is right.\n\nFree Friday at 2?\n\nMaya"),
            message(from: "Sam Okafor <sam@example.org>", subject: "Re: Cabin weekend",
                    snippet: "Booked! Arriving Saturday morning, I'll bring the camp stove.", hoursAgo: 3,
                    labels: ["INBOX", "CATEGORY_PERSONAL"],
                    text: "Booked! Arriving Saturday morning, I'll bring the camp stove.\n\n> Are we still on for the 14th?"),
            message(from: "Priya Natarajan <priya@example.net>", subject: "Intro: Priya ↔ Josh",
                    snippet: "Leo mentioned you're building a mail client. I'd love to compare notes on Gmail's history API.", hoursAgo: 9,
                    labels: ["INBOX", "CATEGORY_PERSONAL"], unread: false,
                    text: "Hi Josh,\n\nLeo mentioned you're building a mail client. I'd love to compare notes on Gmail's history API — we hit the same 404 cliff last year.\n\nPriya"),
            message(from: "Dad <dad@example.com>", subject: "Photos from the beach",
                    snippet: "Finally got them off the camera. The one of the pelican is my favourite.", hoursAgo: 30,
                    labels: ["INBOX", "CATEGORY_PERSONAL"], unread: false,
                    text: "Finally got them off the camera. The one of the pelican is my favourite.\n\nLove, Dad"),
        ]
    }

    private static func newsletterHTML(_ title: String, _ paragraphs: [String]) -> String {
        "<div style=\"max-width:600px;margin:0 auto;font-family:Georgia,serif;font-size:18px;line-height:1.6;color:#222\"><h1 style=\"font-size:28px;line-height:1.2\">\(title)</h1>"
            + paragraphs.map { "<p>\($0)</p>" }.joined() + "<p style=\"font-size:13px;color:#888\">Sample newsletter generated for Dingo’s design review.</p></div>"
    }

    private static func newsletters() -> [ParsedMessage] {
        let list: [(String, String, String)] = [
            ("The Long Commit <issues@longcommit.example>", "Why your sync engine wants a history cursor", "Most sync bugs are ordering bugs. A cursor turns them into resumable work."),
            ("Runtime Weekly <hello@runtimeweekly.example>", "Issue 212: actors, isolation, and the cost of a hop", "This week: measuring actor hops, a tour of Swift 6.4's isolation changes, and three tools."),
            ("Field Notes <notes@fieldnotes.example>", "On quiet software", "The best tools disappear into the work. A short essay on chrome, density, and restraint."),
            ("The Long Commit <issues@longcommit.example>", "The case for boring storage", "SQLite is the most deployed database in the world for a reason."),
            ("Small Batch Design <studio@smallbatch.example>", "Type at 13 points", "Interface type lives in a narrow band. What changes between 11 and 13 points."),
        ]
        return list.enumerated().map { index, item in
            message(from: item.0, subject: item.1, snippet: item.2, hoursAgo: Double(index) * 11 + 2, labels: ["INBOX", "CATEGORY_UPDATES"],
                    unread: index < 3,
                    headers: [("List-Unsubscribe", "<https://\(item.0.split(separator: "@").last!.dropLast())/unsubscribe>"),
                              ("List-Unsubscribe-Post", "List-Unsubscribe=One-Click"), ("List-Id", "<\(index).list.example>"), ("Precedence", "bulk")],
                    html: newsletterHTML(item.1, [item.2, "When a system can say where it left off, every failure becomes a pause instead of a restart. That is the whole trick, and it is worth building around from the first line.", "The rest of this issue walks through three real cursors: Gmail's history ID, a file system's change journal, and a log-structured queue."]))
        }
    }

    private static func notifications() -> [ParsedMessage] {
        let gh: [(String, String, String, Double)] = [
            ("josh/koala", "[josh/koala] Run failed: CI - main (9e1374e)", "The run for 'location/screen permissions' failed: 1 failing job, Build and test.", 0.8),
            ("josh/koala", "Re: [josh/koala] Peek drops scroll position on promote (#212)", "maya commented: Repro'd on 26.1 — the snapshot is taken after the reload.", 2),
            ("josh/dingo", "[josh/dingo] Sync falls back to full sync too often (#4)", "Opened by priya: history 404s after a week offline trigger a full resync.", 5),
            ("josh/dingo", "Re: [josh/dingo] Receipts: parse JSON-LD Invoice (#7)", "Merged #7 into main.", 20),
        ]
        var result = gh.map { repo, subject, snippet, hours in
            message(from: "GitHub <notifications@github.com>", subject: subject, snippet: snippet, hoursAgo: hours, labels: ["INBOX", "CATEGORY_UPDATES"],
                    unread: hours < 6,
                    headers: [("List-Id", "\(repo.split(separator: "/")[1]) <\(repo.split(separator: "/")[1]).\(repo.split(separator: "/")[0]).github.com>"),
                              ("X-GitHub-Reason", "author"), ("List-Unsubscribe", "<https://github.com/notifications/unsubscribe/sample>")],
                    text: "\(snippet)\n\nhttps://github.com/\(repo)/pull/212\n\n—\nReply to this email directly, view it on GitHub.")
        }
        result.append(message(from: "Deploy Bot <alerts@deploys.example>", subject: "Production deploy succeeded: dingo-site",
                              snippet: "Deploy 418 finished in 42s.", hoursAgo: 7, labels: ["INBOX", "CATEGORY_UPDATES"], unread: false,
                              headers: [("Auto-Submitted", "auto-generated")], text: "Deploy 418 finished in 42s.\nhttps://deploys.example/runs/418"))
        result.append(message(from: "Security <no-reply@accounts.example>", subject: "New sign-in on Mac",
                              snippet: "We noticed a new sign-in to your account from a Mac in Brooklyn.", hoursAgo: 26, labels: ["INBOX", "CATEGORY_UPDATES"], unread: false,
                              headers: [("Auto-Submitted", "auto-generated")]))
        return result
    }

    private static func receiptHTML(_ merchant: String, _ order: String, _ total: String) -> String {
        """
        <script type="application/ld+json">{"@context":"http://schema.org","@type":"Order","merchant":{"@type":"Organization","name":"\(merchant)"},"orderNumber":"\(order)","priceCurrency":"USD","price":"\(total)","orderStatus":"http://schema.org/OrderProcessing"}</script>
        <div style="font-family:Helvetica,Arial,sans-serif;max-width:560px;margin:0 auto"><h2>Thanks for your order</h2><p>Order \(order)</p><p><b>Total: $\(total)</b></p><p style="color:#888;font-size:12px">Sample receipt generated for Dingo’s design review.</p></div>
        """
    }

    private static func receipts() -> [ParsedMessage] {
        let items: [(String, String, String, String, Double)] = [
            ("Bayside Coffee <receipts@baysidecoffee.example>", "Your Bayside Coffee receipt", "BC-20931", "14.50", 4),
            ("Northline Hardware <orders@northline.example>", "Order confirmation #NL-55812", "NL-55812", "86.20", 28),
            ("Cloudlet <billing@cloudlet.example>", "Invoice for November", "INV-2026-11", "24.00", 50),
            ("Paper & Ink <orders@paperink.example>", "Your order has shipped", "PI-7731", "39.95", 120),
            ("Cloudlet <billing@cloudlet.example>", "Invoice for October", "INV-2026-10", "24.00", 24 * 31),
        ]
        return items.map { from, subject, order, total, hours in
            message(from: from, subject: subject, snippet: "Order \(order) · Total $\(total)", hoursAgo: hours, labels: ["INBOX", "CATEGORY_UPDATES"],
                    unread: false, html: receiptHTML(String(from.split(separator: "<")[0]).trimmingCharacters(in: .whitespaces), order, total))
        }
    }

    private static func ics(_ summary: String, start: Date, minutes: Int, organizer: String, method: String = "REQUEST") -> String {
        let format = DateFormatter()
        format.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        format.timeZone = TimeZone(identifier: "UTC")
        return """
        BEGIN:VCALENDAR\r
        PRODID:-//Dingo Sample//EN\r
        VERSION:2.0\r
        METHOD:\(method)\r
        BEGIN:VEVENT\r
        UID:\(summary.hashValue)@dingo.test\r
        SEQUENCE:0\r
        DTSTART:\(format.string(from: start))\r
        DTEND:\(format.string(from: start.addingTimeInterval(Double(minutes) * 60)))\r
        SUMMARY:\(summary)\r
        LOCATION:https://meet.example/abc-defg\r
        ORGANIZER;CN=\(organizer):mailto:\(organizer.lowercased().replacingOccurrences(of: " ", with: "."))@example.com\r
        ATTENDEE;CN=Josh;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:sample@dingo.test\r
        ATTENDEE;CN=Maya Chen;PARTSTAT=ACCEPTED:mailto:maya@example.com\r
        ATTENDEE;CN=Sam Okafor;PARTSTAT=TENTATIVE:mailto:sam@example.org\r
        DESCRIPTION:Agenda: walk through the history-expired path\\, then decide on the window.\r
        END:VEVENT\r
        END:VCALENDAR\r
        """
    }

    private static func invites() -> [ParsedMessage] {
        let calendar = Calendar.current
        let today = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: Date())!
        let friday = calendar.nextDate(after: Date(), matching: DateComponents(hour: 14, weekday: 6), matchingPolicy: .nextTime)!
        return [
            message(from: "Maya Chen <maya.chen@example.com>", subject: "Invitation: Sync rewrite walkthrough @ Fri 2pm",
                    snippet: "Maya Chen has invited you to Sync rewrite walkthrough", hoursAgo: 1,
                    calendar: ics("Sync rewrite walkthrough", start: friday, minutes: 45, organizer: "Maya Chen")),
            message(from: "Priya Natarajan <priya.natarajan@example.com>", subject: "Invitation: Compare notes on Gmail history",
                    snippet: "Priya Natarajan has invited you", hoursAgo: 8,
                    calendar: ics("Compare notes on Gmail history", start: today.addingTimeInterval(3 * 86400), minutes: 30, organizer: "Priya Natarajan")),
            message(from: "Sam Okafor <sam.okafor@example.com>", subject: "Canceled event: Climbing",
                    snippet: "This event has been canceled", hoursAgo: 12,
                    calendar: ics("Climbing", start: today.addingTimeInterval(86400), minutes: 90, organizer: "Sam Okafor", method: "CANCEL")),
        ]
    }
}
#endif
