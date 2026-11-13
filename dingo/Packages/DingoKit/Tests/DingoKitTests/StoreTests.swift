import Foundation
import GRDB
import Testing
@testable import DingoKit

@Suite struct StoreTests {
    typealias F = BucketFixtures

    let store: MailStore
    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    init() async throws {
        store = MailStore(database: try AppDatabase.inMemory())
        try await store.upsert(MailAccount(email: F.me, displayName: "Me", sendAs: [EmailAddress(name: "Me", email: "alias@example.org")]))
    }

    func day(_ n: Double) -> Date { F.baseDate.addingTimeInterval(n * 86_400) }

    func save(_ messages: ParsedMessage..., bucket: Bucket) async throws {
        try await store.save(messages) { _ in bucket }
    }

    func threads(_ bucket: Bucket, accountIDs: Set<String>? = nil, limit: Int = 100, before: Date? = nil) async throws -> [ThreadSummary] {
        try await store.read { db in try MailStore.threads(db, bucket: bucket, accountIDs: accountIDs, limit: limit, before: before) }
    }

    func message(_ id: String) async throws -> MailMessage? {
        try await store.message(accountID: F.me, messageID: id)
    }

    func unreadCounts() async throws -> [Bucket: Int] {
        try await store.read { db in try MailStore.unreadCounts(db, accountIDs: nil) }
    }

    /// The first value an observation delivers that satisfies `condition`.
    func first<T: Sendable>(_ observation: AsyncValueObservation<T>, where condition: (T) -> Bool) async throws -> T? {
        for try await value in observation where condition(value) { return value }
        return nil
    }

    // MARK: - Schema

    @Test func migrationsCreateEveryTable() throws {
        let database = try AppDatabase.inMemory()
        let tables = ["account", "label", "message", "messageBody", "attachment", "senderRule", "receipt", "calendarEvent", "message_fts"]
        let (applied, existing, indexes) = try database.writer.read { db in
            (try AppDatabase.migrator.appliedMigrations(db), try tables.filter { try db.tableExists($0) },
             try db.indexes(on: "message").map(\.columns))
        }
        #expect(applied == ["v1", "v2", "v3"])
        #expect(existing == tables)
        #expect(indexes.contains(["bucket", "internalDate"]))
        #expect(indexes.contains(["accountID", "threadID"]))
        #expect(indexes.contains(["bucket", "isFiled", "internalDate"]))
    }

    @Test func v3ForgetsBodiesWithInlineParts() async throws {
        try await save(F.message(id: "plain", from: "Ada <ada@example.com>", subject: "Text", date: day(0)),
                       F.message(id: "photo", from: "Ada <ada@example.com>", subject: "Photo", date: day(1)), bucket: .inbox)
        try await store.saveBody(ParsedMessage.Body(text: "hi"), accountID: F.me, messageID: "plain")
        try await store.saveBody(ParsedMessage.Body(text: "see photo", inline: ["p": .init(mimeType: "image/jpeg", attachmentID: "a")]),
                                 accountID: F.me, messageID: "photo")
        // Run v3 again over bodies stored the old way.
        try await store.writer.write { db in try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v3'") }
        try AppDatabase.migrator.migrate(store.writer)

        #expect(try await store.body(accountID: F.me, messageID: "plain")?.text == "hi")
        #expect(try await store.body(accountID: F.me, messageID: "photo") == nil)
        #expect(try await message("plain")?.bodyState == .fetched)
        #expect(try await message("photo")?.bodyState == MailMessage.BodyState.none)
    }

    @Test func accountUpsertKeepsSyncState() async throws {
        try await store.setHistoryID(42, accountID: F.me)
        try await store.upsert(MailAccount(email: F.me, displayName: "Renamed"))
        #expect(try await store.historyID(accountID: F.me) == 42)
        let account = try #require(try await store.accounts().first)
        #expect(account.displayName == "Renamed")
        #expect(account.lastSyncAt != nil)
    }

    // MARK: - Threads

    @Test func threadsPerBucket() async throws {
        let incoming = F.message(id: "m1", thread: "t1", from: "Ada <ada@example.com>", subject: "Lunch?", date: day(0),
                                 attachments: [.init(filename: "menu.pdf", mimeType: "application/pdf", size: 1, attachmentID: "a")])
        let reply = F.message(id: "m2", thread: "t1", from: "Me <me@example.org>", subject: "Re: Lunch?", labels: ["SENT", "STARRED"], date: day(1))
        let archived = F.message(id: "m3", from: "Bob <bob@example.com>", subject: "Old", labels: [], date: day(2))
        let trashed = F.message(id: "m4", from: "Eve <eve@example.com>", subject: "Spam", labels: ["TRASH", "INBOX"], date: day(3))
        try await save(incoming, reply, archived, trashed, bucket: .inbox)
        let issue = F.message(id: "n1", from: "Platformer <casey@platformer.news>", subject: "Weekly", labels: ["INBOX", "UNREAD"], date: day(4))
        try await save(issue, bucket: .newsletters)

        let inbox = try await threads(.inbox)
        #expect(inbox.map(\.threadID) == ["t1"])
        let thread = try #require(inbox.first)
        #expect(thread.messageCount == 2)
        #expect(thread.latest.id == "m2")
        #expect(thread.hasUnread && thread.isStarred && thread.hasAttachments)
        #expect(thread.participants.map(\.email) == ["ada@example.com", "me@example.org"])

        #expect(try await threads(.newsletters).map(\.latest.id) == ["n1"])
        #expect(try await threads(.newsletters).first?.isStarred == false)
        #expect(try await threads(.notifications).isEmpty)
        #expect(try await threads(.newsletters, accountIDs: ["other@example.org"]).isEmpty)
        #expect(try await store.thread(accountID: F.me, threadID: "t1").map(\.id) == ["m1", "m2"])
    }

    @Test func threadsByGmailLabel() async throws {
        try await save(F.message(id: "s1", thread: "a", from: "Me <me@example.org>", subject: "Sent", labels: ["SENT"], date: day(0)),
                       F.message(id: "s2", thread: "b", from: "Ada <ada@example.com>", subject: "Starred", labels: ["STARRED", "INBOX"], date: day(1)),
                       F.message(id: "s3", thread: "c", from: "Me <me@example.org>", subject: "Draft", labels: ["DRAFT"], date: day(2)),
                       F.message(id: "s4", thread: "d", from: "Me <me@example.org>", subject: "Gone", labels: ["SENT", "TRASH"], date: day(3)),
                       bucket: .inbox)
        try await save(F.message(id: "s5", thread: "e", from: "P <casey@platformer.news>", subject: "x", labels: ["STARRED"], date: day(4)),
                       bucket: .newsletters)
        func ids(_ label: String) async throws -> [String] {
            try await store.read { db in try MailStore.threads(db, labelID: label, accountIDs: nil, limit: 10).map(\.threadID) }
        }
        #expect(try await ids("SENT") == ["a"])
        #expect(try await ids("STARRED") == ["e", "b"])
        #expect(try await ids("DRAFT") == ["c"])
    }

    @Test func threadPaging() async throws {
        for n in 0..<5 {
            try await save(F.message(id: "p\(n)", from: "Ada <ada@example.com>", subject: "Note \(n)", date: day(Double(n))), bucket: .inbox)
        }
        let first = try await threads(.inbox, limit: 2)
        #expect(first.map(\.threadID) == ["p4", "p3"])
        let next = try await threads(.inbox, limit: 2, before: first.last?.date)
        #expect(next.map(\.threadID) == ["p2", "p1"])
    }

    @Test func unreadCountsByThread() async throws {
        try await save(F.message(id: "a", thread: "t", from: "A <a@x.example>", subject: "1"),
                       F.message(id: "b", thread: "t", from: "A <a@x.example>", subject: "2"),
                       F.message(id: "c", from: "A <a@x.example>", subject: "3", labels: ["INBOX"]),
                       F.message(id: "d", from: "A <a@x.example>", subject: "archived", labels: ["UNREAD"]),
                       F.message(id: "x", from: "A <a@x.example>", subject: "trash", labels: ["UNREAD", "INBOX", "TRASH"]), bucket: .inbox)
        try await save(F.message(id: "e", from: "Gh <notifications@github.com>", subject: "x"), bucket: .notifications)
        #expect(try await unreadCounts() == [.inbox: 1, .notifications: 1, .newsletters: 0, .receipts: 0, .calendar: 0])

        try await store.setUnread(false, .thread("t"), accountID: F.me)
        #expect(try await unreadCounts()[.inbox] == 0)
    }

    @Test func syncLabelUpdatesKeepFlagsInStep() async throws {
        try await save(F.message(id: "m", from: "A <a@x.example>", subject: "s", labels: ["INBOX", "UNREAD"]), bucket: .inbox)
        try await store.updateLabels(["m": ["STARRED", "SPAM"], "unknown": ["INBOX"]], accountID: F.me)
        let message = try #require(try await message("m"))
        #expect(!message.isUnread && message.isStarred && !message.isInInbox && message.isTrashOrSpam)
        #expect(message.labelIDs == ["STARRED", "SPAM"])
    }

    // MARK: - Optimistic actions

    @Test func actionsChangeLabelsAndRestore() async throws {
        try await save(F.message(id: "a", thread: "t", from: "A <a@x.example>", subject: "1", labels: ["INBOX", "UNREAD"]),
                       F.message(id: "b", thread: "t", from: "A <a@x.example>", subject: "2", labels: ["INBOX"]), bucket: .inbox)

        let starred = try await store.setStarred(true, .messages(["b"]), accountID: F.me)
        #expect(starred.messageIDs == ["b"])
        #expect(try await message("b")?.isStarred == true)

        let archived = try await store.archive(.thread("t"), accountID: F.me)
        #expect(archived.labelIDs == ["a": ["INBOX", "UNREAD"], "b": ["INBOX", "STARRED"]])
        #expect(try await threads(.inbox).isEmpty)
        #expect(try await message("a")?.labelIDs == ["UNREAD"])

        try await store.restore(archived)
        #expect(try await threads(.inbox).map(\.threadID) == ["t"])

        let trashed = try await store.trash(.thread("t"), accountID: F.me)
        #expect(try await store.thread(accountID: F.me, threadID: "t").isEmpty)
        try await store.restore(trashed)
        #expect(try await store.thread(accountID: F.me, threadID: "t").count == 2)
    }

    @Test func moveThreadToBucketUsesDingoLabelAndLeavesSentMail() async throws {
        try await store.replaceLabels([MailLabel(accountID: F.me, id: "Label_N", name: "Dingo/Newsletters", type: "user"),
                                       MailLabel(accountID: F.me, id: "Label_R", name: "Dingo/Receipts", type: "user")], accountID: F.me)
        try await save(F.message(id: "a", thread: "t", from: "P <casey@platformer.news>", subject: "Issue", labels: ["INBOX", "Label_R"], date: day(0)),
                       F.message(id: "b", thread: "t", from: "Me <me@example.org>", subject: "Re: Issue", labels: ["SENT"], date: day(1)),
                       bucket: .inbox)
        let snapshot = try await store.moveToBucket(.newsletters, .thread("t"), accountID: F.me)
        #expect(snapshot.messageIDs == ["a"])
        let moved = try #require(try await message("a"))
        #expect(moved.bucket == .newsletters && moved.isInInbox, "moving to a bucket never skips the Inbox")
        #expect(moved.labelIDs == ["INBOX", "Label_N"])
        #expect(try await message("b")?.bucket == .inbox)
        #expect(try await threads(.newsletters).first?.messageCount == 2)
        #expect(try await threads(.inbox).isEmpty)

        try await store.moveToBucket(.inbox, .messages(["a"]), accountID: F.me)
        #expect(try await message("a")?.labelIDs == ["INBOX"])
        try await store.restore(snapshot)
        #expect(try await message("a")?.labelIDs == ["INBOX", "Label_R"])
        #expect(try await message("a")?.bucket == .inbox)
    }

    @Test func movingIntoReceiptsDerivesAReceipt() async throws {
        try await save(F.message(id: "m", from: "Shop <hello@shop.example>", subject: "Thanks", text: "Order total: $30.00"), bucket: .inbox)
        #expect(try await store.receipt(accountID: F.me, messageID: "m") == nil)
        try await store.moveToBucket(.receipts, .messages(["m"]), accountID: F.me)
        #expect(try await store.receipt(accountID: F.me, messageID: "m")?.amount == 30)
        #expect(try await threads(.receipts).map(\.latest.id) == ["m"])
    }

    // MARK: - Filing

    static let dingoLabels = [
        MailLabel(accountID: F.me, id: "Label_N", name: "Dingo/Newsletters", type: "user"),
        MailLabel(accountID: F.me, id: "Label_R", name: "Dingo/Receipts", type: "user"),
        MailLabel(accountID: F.me, id: "Label_C", name: "Dingo/Invites", type: "user"),
    ]

    @Test func filedMeansInboxOrOwnBucketLabel() async throws {
        try await store.replaceLabels(Self.dingoLabels, accountID: F.me)
        try await save(F.message(id: "own", from: "P <a@p.example>", subject: "1", labels: ["Label_N", "UNREAD"]),
                       F.message(id: "inbox", from: "P <b@p.example>", subject: "2", labels: ["INBOX"]),
                       F.message(id: "other", from: "P <c@p.example>", subject: "3", labels: ["Label_R", "UNREAD"]),
                       F.message(id: "none", from: "P <d@p.example>", subject: "4", labels: ["UNREAD", "STARRED"]),
                       bucket: .newsletters)
        #expect(try await message("own")?.isFiled == true)
        #expect(try await message("inbox")?.isFiled == true)
        #expect(try await message("other")?.isFiled == false, "another bucket's label does not file it here")
        #expect(try await message("none")?.isFiled == false)
        #expect(Set(try await threads(.newsletters).map(\.threadID)) == ["own", "inbox"])
        #expect(try await unreadCounts()[.newsletters] == 1)
        let publications = try await store.read { db in try MailStore.publications(db, accountIDs: nil) }
        #expect(Set(publications.map(\.id)) == ["a@p.example", "b@p.example"])
        let starred = try await store.read { db in try MailStore.threads(db, labelID: "STARRED", accountIDs: nil, limit: 10) }
        #expect(starred.map(\.threadID) == ["none"], "label views ignore filing")
    }

    @Test func labelsArrivingLaterFileMessages() async throws {
        try await save(F.message(id: "m", from: "P <a@p.example>", subject: "1", labels: ["Label_N"]), bucket: .newsletters)
        #expect(try await threads(.newsletters).isEmpty)
        try await store.replaceLabels(Self.dingoLabels, accountID: F.me)
        #expect(try await threads(.newsletters).map(\.threadID) == ["m"])
        try await store.updateLabels(["m": ["UNREAD"]], accountID: F.me)
        #expect(try await message("m")?.isFiled == false)
    }

    @Test func archiveRemovesInboxAndDingoLabels() async throws {
        try await store.replaceLabels(Self.dingoLabels, accountID: F.me)
        try await save(F.message(id: "r", from: "Shop <orders@shop.example>", subject: "Receipt", labels: ["Label_R", "INBOX", "UNREAD"],
                                 text: "Total $9.00"), bucket: .receipts)
        #expect(try await store.read { db in try MailStore.receiptMonths(db, accountIDs: nil, calendar: Self.utcCalendar) }.count == 1)
        let snapshot = try await store.archive(.messages(["r"]), accountID: F.me)
        #expect(try await message("r")?.labelIDs == ["UNREAD"])
        #expect(try await threads(.receipts).isEmpty)
        #expect(try await unreadCounts()[.receipts] == 0)
        #expect(try await store.read { db in try MailStore.receiptMonths(db, accountIDs: nil, calendar: Self.utcCalendar) }.isEmpty)
        try await store.restore(snapshot)
        #expect(try await threads(.receipts).map(\.threadID) == ["r"])
    }

    @Test func archivedInvitesLeaveEvents() async throws {
        try await store.replaceLabels(Self.dingoLabels, accountID: F.me)
        try await save(F.message(id: "c", from: "Ada <ada@example.com>", subject: "Invitation", labels: ["Label_C"],
                                 calendar: try F.fixture("google-invite.ics")), bucket: .calendar)
        #expect(try await store.read { db in try MailStore.events(db, accountIDs: nil) }.count == 1)
        try await store.archive(.thread("c"), accountID: F.me)
        #expect(try await store.read { db in try MailStore.events(db, accountIDs: nil) }.isEmpty)
    }

    @Test func setLabelsAppliesEditsAndRefiles() async throws {
        try await store.replaceLabels(Self.dingoLabels, accountID: F.me)
        try await save(F.message(id: "a", from: "P <a@p.example>", subject: "1", labels: ["INBOX", "UNREAD"]),
                       F.message(id: "b", from: "P <b@p.example>", subject: "2", labels: ["INBOX"]), bucket: .newsletters)
        let snapshot = try await store.setLabels(accountID: F.me, changes: [
            "a": (add: ["Label_N"], remove: ["INBOX", "UNREAD"]),
            "b": (add: ["STARRED"], remove: ["INBOX"]),
        ])
        let a = try #require(try await message("a"))
        #expect(a.labelIDs == ["Label_N"] && a.isFiled && !a.isUnread && !a.isInInbox)
        let b = try #require(try await message("b"))
        #expect(b.isStarred && !b.isFiled)
        #expect(try await threads(.newsletters).map(\.threadID) == ["a"])
        try await store.restore(snapshot)
        #expect(try await message("b")?.isFiled == true)
    }

    @Test func moveWithoutDingoLabelKeepsInbox() async throws {
        try await save(F.message(id: "m", from: "P <a@p.example>", subject: "1"), bucket: .inbox)
        try await store.moveToBucket(.notifications, .messages(["m"]), accountID: F.me)
        let moved = try #require(try await message("m"))
        #expect(moved.isInInbox && moved.isFiled && moved.bucket == .notifications)
        #expect(try await threads(.inbox).isEmpty)
        #expect(try await threads(.notifications).map(\.threadID) == ["m"])
    }

    @Test func syncSetBucketRefiles() async throws {
        try await store.replaceLabels(Self.dingoLabels, accountID: F.me)
        try await save(F.message(id: "m", from: "P <a@p.example>", subject: "1", labels: ["Label_R"]), bucket: .newsletters)
        #expect(try await message("m")?.isFiled == false)
        try await store.setBucket(.receipts, accountID: F.me, messageIDs: ["m"])
        #expect(try await message("m")?.isFiled == true)
        #expect(try await message("m")?.labelIDs == ["Label_R"], "sync's labels are left alone")
        #expect(try await store.receipt(accountID: F.me, messageID: "m") != nil)
        #expect(try await threads(.receipts).map(\.threadID) == ["m"])
    }

    // MARK: - Bodies and search

    @Test func searchFindsBodyTextThatArrivesLater() async throws {
        let metadata = F.message(id: "s1", from: "Ada Lovelace <ada@example.com>", subject: "Quarterly notes", snippet: "see attached")
        try await save(metadata, bucket: .inbox)
        #expect(try await store.search("quart").map(\.id) == ["s1"])
        #expect(try await store.search("lovel").map(\.id) == ["s1"])
        #expect(try await store.search("kangaroo").isEmpty)

        var full = metadata
        full.body = ParsedMessage.Body(html: "<p>The <b>kangaroo</b> budget &amp; plan</p><style>.x{color:red}</style>")
        try await save(full, bucket: .inbox)
        #expect(try await store.search("kangar").map(\.id) == ["s1"])
        #expect(try await store.search("quarterly kangaroo").map(\.id) == ["s1"], "words split across subject and body")
        #expect(try await store.search("color").isEmpty, "style blocks are not indexed")

        // A later metadata-only save keeps the body and its index entry.
        try await save(metadata, bucket: .inbox)
        #expect(try await store.search("kangaroo").map(\.id) == ["s1"])
        #expect(try await message("s1")?.bodyState == .fetched)
        #expect(try await store.body(accountID: F.me, messageID: "s1")?.html?.contains("kangaroo") == true)
    }

    @Test func saveBodyAfterMetadata() async throws {
        try await save(F.message(id: "b1", from: "Ada <ada@example.com>", subject: "Invitation: Review", date: day(0)),
                       F.message(id: "b2", from: "Ada <ada@example.com>", subject: "Other", date: day(1)),
                       F.message(id: "b3", from: "Ada <ada@example.com>", subject: "Old", date: day(-30)), bucket: .calendar)
        #expect(try await store.messageIDsMissingBodies(accountID: F.me) == ["b2", "b1", "b3"])
        #expect(try await store.messageIDsMissingBodies(accountID: F.me, newerThan: day(-1), limit: 1) == ["b2"])
        #expect(try await store.knownMessageIDs(accountID: F.me) == ["b1", "b2", "b3"])

        try await store.saveBody(ParsedMessage.Body(text: "platypus agenda", calendar: try F.fixture("google-invite.ics")),
                                 attachments: [.init(filename: "invite.ics", mimeType: "text/calendar", size: 900, attachmentID: "x")],
                                 accountID: F.me, messageID: "b1")
        try await store.markBodiesFetched(accountID: F.me, messageIDs: ["b2"])
        #expect(try await store.messageIDsMissingBodies(accountID: F.me) == ["b3"])
        #expect(try await store.search("platypus").map(\.id) == ["b1"])
        #expect(try await store.attachments(accountID: F.me, messageID: "b1").map(\.filename) == ["invite.ics"])
        #expect(try await message("b1")?.hasAttachments == true)
        let events = try await store.read { db in try MailStore.events(db, accountIDs: nil) }
        #expect(events.map(\.message.id) == ["b1"])
        #expect(events.first?.event.summary == "Dingo design review")

        try await store.remove(accountID: F.me, messageIDs: ["b1"])
        #expect(try await store.knownMessageIDs(accountID: F.me) == ["b2", "b3"])
        #expect(try await store.read { db in try MailStore.events(db, accountIDs: nil) }.isEmpty)
    }

    @Test func downloadedInlinePartIsKept() async throws {
        try await save(F.message(id: "i1", from: "Ada <ada@example.com>", subject: "Logo", date: day(0)), bucket: .inbox)
        try await store.saveBody(ParsedMessage.Body(html: #"<img src="cid:logo">"#,
                                                    inline: ["<logo>": .init(mimeType: "image/png", attachmentID: "att")]),
                                 accountID: F.me, messageID: "i1")
        try await store.saveInlineData(Data([1, 2, 3]), cid: "<logo>", accountID: F.me, messageID: "i1")
        try await store.saveInlineData(Data([9]), cid: "<missing>", accountID: F.me, messageID: "i1")

        let inline = try await store.body(accountID: F.me, messageID: "i1")?.inline
        #expect(inline?["<logo>"]?.data == Data([1, 2, 3]))
        #expect(inline?["<logo>"]?.attachmentID == "att")
        #expect(inline?.count == 1, "an unknown Content-ID adds nothing")
    }

    @Test func searchIsNewestFirstAndSkipsTrash() async throws {
        try await save(F.message(id: "old", from: "A <a@x.example>", subject: "Invoice one", date: day(0)),
                       F.message(id: "new", from: "A <a@x.example>", subject: "Invoice two", date: day(1)),
                       F.message(id: "gone", from: "A <a@x.example>", subject: "Invoice three", labels: ["TRASH"], date: day(2)),
                       bucket: .inbox)
        #expect(try await store.search("invoice").map(\.id) == ["new", "old"])
        #expect(try await store.search("invoice", limit: 1).map(\.id) == ["new"])
        #expect(try await store.search("  ").isEmpty)
    }

    @Test func attachmentsAndInlinePartsRoundTrip() async throws {
        var message = F.message(id: "att", from: "A <a@x.example>", subject: "Files", text: "see files",
                                attachments: [.init(filename: "a.pdf", mimeType: "application/pdf", size: 10, attachmentID: "x1"),
                                              .init(filename: "b.png", mimeType: "image/png", size: 20, attachmentID: nil)])
        message.body?.inline = ["logo": .init(mimeType: "image/png", data: Data([1, 2, 3]))]
        try await save(message, bucket: .inbox)
        #expect(try await store.attachments(accountID: F.me, messageID: "att").map(\.filename) == ["a.pdf", "b.png"])
        #expect(try await store.body(accountID: F.me, messageID: "att")?.inline["logo"]?.data == Data([1, 2, 3]))

        var metadata = message
        metadata.body = nil
        metadata.attachments = []
        try await save(metadata, bucket: .inbox)
        #expect(try await store.attachments(accountID: F.me, messageID: "att").count == 2)
        #expect(try await self.message("att")?.hasAttachments == true)
    }

    @Test func removeDeletesEverythingDerived() async throws {
        try await save(F.message(id: "r", from: "Shop <orders@shop.example>", subject: "Receipt kiwi", text: "Total $5.00"), bucket: .receipts)
        #expect(try await store.receipt(accountID: F.me, messageID: "r")?.amount == 5)
        try await store.remove(accountID: F.me, messageIDs: ["r"])
        #expect(try await message("r") == nil)
        #expect(try await store.body(accountID: F.me, messageID: "r") == nil)
        #expect(try await store.receipt(accountID: F.me, messageID: "r") == nil)
        #expect(try await store.search("kiwi").isEmpty)
    }

    @Test func removingAnAccountRemovesItsMail() async throws {
        try await save(F.message(id: "x", from: "A <a@x.example>", subject: "s", text: "t"), bucket: .inbox)
        try await store.removeAccount(F.me)
        #expect(try await message("x") == nil)
        #expect(try await store.accounts().isEmpty)
    }

    // MARK: - Sender rules

    @Test func senderRulePrecedence() async throws {
        try await store.upsert(MailAccount(email: "work@example.org"))
        try await store.setRule(matcher: "Example.com", bucket: .notifications)
        try await store.setRule(matcher: "ceo@example.com", bucket: .inbox)
        try await store.setRule(matcher: "@example.com", bucket: .newsletters, accountID: "work@example.org")

        #expect(try await store.rule(for: EmailAddress(email: "ceo@example.com"), accountID: F.me)?.bucket == .inbox)
        #expect(try await store.rule(for: EmailAddress(email: "bot@example.com"), accountID: F.me)?.bucket == .notifications)
        #expect(try await store.rule(for: EmailAddress(email: "bot@example.com"), accountID: "work@example.org")?.bucket == .newsletters)
        #expect(try await store.rule(for: EmailAddress(email: "ceo@example.com"), accountID: "work@example.org")?.bucket == .inbox)
        #expect(try await store.rule(for: EmailAddress(email: "x@other.example"), accountID: F.me) == nil)
    }

    @Test func settingARuleAgainUpdatesIt() async throws {
        let first = try await store.setRule(matcher: "@shop.example", bucket: .newsletters)
        let second = try await store.setRule(matcher: "@SHOP.example", bucket: .receipts)
        #expect(first.id == second.id)
        #expect(try await store.rules().map(\.bucket) == [.receipts])
        try await store.deleteRule(id: try #require(second.id))
        #expect(try await store.rules().isEmpty)
    }

    @Test func globalRulesAreUniquePerMatcher() async throws {
        try await store.setRule(matcher: "@shop.example", bucket: .newsletters)
        await #expect(throws: DatabaseError.self) {
            try await store.database.writer.write { db in
                var duplicate = SenderRule(matcher: "@shop.example", bucket: .receipts)
                try duplicate.insert(db)
            }
        }
    }

    @Test func classifierLoadsRulesAndDingoLabels() async throws {
        try await store.replaceLabels([MailLabel(accountID: F.me, id: "Label_1", name: "Dingo/Invites", type: "user")], accountID: F.me)
        try await store.setRule(matcher: "@platformer.news", bucket: .newsletters)
        let classifier = try await store.classifier(accountID: F.me)
        #expect(classifier.classify(F.message(from: "P <casey@platformer.news>", subject: "x")) == .newsletters)
        #expect(classifier.classify(F.message(from: "A <a@x.example>", subject: "x", labels: ["Label_1"])) == .calendar)
    }

    // MARK: - Bucket views

    @Test func publicationsAndIssues() async throws {
        try await save(F.message(id: "p1", from: "Platformer <casey@platformer.news>", subject: "One", labels: ["INBOX"], date: day(0)),
                       F.message(id: "p2", from: "Platformer <Casey@platformer.news>", subject: "Two", labels: ["INBOX", "UNREAD"],
                                 headers: [("List-Unsubscribe", "<https://platformer.news/u>"), ("List-Unsubscribe-Post", "List-Unsubscribe=One-Click")],
                                 date: day(2)),
                       F.message(id: "s1", from: "Stratechery <ben@stratechery.example>", subject: "Hi", date: day(1)),
                       bucket: .newsletters)
        let publications = try await store.read { db in try MailStore.publications(db, accountIDs: nil) }
        #expect(publications.map(\.id) == ["casey@platformer.news", "ben@stratechery.example"])
        let platformer = publications[0]
        #expect(platformer.issueCount == 2 && platformer.unreadCount == 1 && platformer.latestIssue.id == "p2")
        #expect(platformer.name == "Platformer" && platformer.latestDate == day(2))
        #expect(platformer.listUnsubscribe == "<https://platformer.news/u>")
        #expect(platformer.listUnsubscribePost == "List-Unsubscribe=One-Click")

        let issues = try #require(try await first(store.observeIssues(publication: "Casey@platformer.news")) { !$0.isEmpty })
        #expect(issues.map(\.id) == ["p2", "p1"])
        let all = try #require(try await first(store.observeIssues(publication: nil)) { !$0.isEmpty })
        #expect(all.map(\.id) == ["p2", "s1", "p1"])
    }

    @Test func notificationsGroupByRepositoryElseDomain() async throws {
        let list = [("List-Id", "dingo/dingo <dingo.dingo.github.com>")]
        try await save(F.message(id: "g1", from: "A <notifications@github.com>", subject: "a", headers: list, date: day(0)),
                       F.message(id: "g2", from: "B <notifications@github.com>", subject: "b", headers: list, date: day(1)),
                       F.message(id: "g3", from: "C <notifications@github.com>", subject: "c",
                                 headers: [("List-Id", "<koala.josh.github.com>")], date: day(2)),
                       F.message(id: "l1", from: "Linear <notifications@linear.app>", subject: "d", labels: ["INBOX"], date: day(3)),
                       bucket: .notifications)
        let sources = try #require(try await first(store.observeNotificationSources()) { !$0.isEmpty })
        #expect(sources.map(\.id) == ["linear.app", "josh/koala", "dingo/dingo"])
        #expect(sources.map(\.title) == ["Linear", "josh/koala", "dingo/dingo"])
        #expect(sources.map(\.kind) == [.other, .github, .github])
        #expect(sources[2].count == 2 && sources[2].unreadCount == 2 && sources[2].latestDate == day(1))
        #expect(sources[0].unreadCount == 0)

        let repo = try #require(try await first(store.observeNotifications(source: "dingo/dingo")) { !$0.isEmpty })
        #expect(repo.map(\.id) == ["g2", "g1"])
        let all = try #require(try await first(store.observeNotifications(source: nil, limit: 3)) { !$0.isEmpty })
        #expect(all.map(\.id) == ["l1", "g3", "g2"])
    }

    @Test func receiptsByMonthWithTotalsPerCurrency() async throws {
        let nov = try Date("2026-11-05T12:00:00Z", strategy: .iso8601)
        let oct = try Date("2026-10-20T12:00:00Z", strategy: .iso8601)
        try await save(F.message(id: "r1", from: "Shop <orders@shop.example>", subject: "Receipt", date: nov, text: "Total $10.25"),
                       F.message(id: "r2", from: "Shop <orders@shop.example>", subject: "Receipt", date: nov.addingTimeInterval(3_600), text: "Total $4.75"),
                       F.message(id: "r3", from: "Bahn <billing@bahn.example>", subject: "Receipt", date: nov, text: "Total: €12,50"),
                       F.message(id: "r4", from: "Shop <orders@shop.example>", subject: "Receipt", date: oct, text: "Total $1.00"),
                       bucket: .receipts)
        let months = try #require(try await first(store.observeReceiptMonths(calendar: Self.utcCalendar)) { !$0.isEmpty })
        #expect(months.count == 2)
        #expect(months[0].month == (try Date("2026-11-01T00:00:00Z", strategy: .iso8601)))
        #expect(months[0].count == 3)
        #expect(months[0].totals == ["USD": 15, "EUR": Decimal(string: "12.5")!])
        #expect(months[1].totals == ["USD": 1] && months[1].count == 1)

        let november = try #require(try await first(store.observeReceipts(month: nov, calendar: Self.utcCalendar)) { !$0.isEmpty })
        #expect(november.map(\.receipt.messageID).first == "r2")
        #expect(Set(november.map(\.message.id)) == ["r1", "r2", "r3"])
        let all = try #require(try await first(store.observeReceipts(month: nil, calendar: Self.utcCalendar)) { !$0.isEmpty })
        #expect(all.count == 4)
    }

    @Test func eventsOneRowPerInvite() async throws {
        let invite = try F.fixture("google-invite.ics")
        let updated = invite.replacingOccurrences(of: "SEQUENCE:0", with: "SEQUENCE:1")
            .replacingOccurrences(of: "SUMMARY:Dingo design review", with: "SUMMARY:Dingo design review (moved)")
        let old = """
            BEGIN:VCALENDAR\nMETHOD:REQUEST\nBEGIN:VEVENT\nUID:old@example.com\nDTSTART:20261101T170000Z\nDTEND:20261101T180000Z
            SUMMARY:Retro\nATTENDEE;PARTSTAT=ACCEPTED:mailto:alias@example.org\nEND:VEVENT\nEND:VCALENDAR
            """
        try await save(F.message(id: "c1", from: "Ada <ada@example.com>", subject: "Invitation: Dingo design review", date: day(0), calendar: invite),
                       F.message(id: "c2", from: "Ada <ada@example.com>", subject: "Updated invitation", date: day(1), calendar: updated),
                       F.message(id: "c3", from: "Ada <ada@example.com>", subject: "Invitation: Retro", date: day(-10), calendar: old),
                       bucket: .calendar)
        let events = try #require(try await first(store.observeEvents()) { !$0.isEmpty })
        #expect(events.map(\.message.id) == ["c3", "c2"])
        #expect(events[1].event.summary == "Dingo design review (moved)")
        #expect(events[1].event.myResponse == nil)
        #expect(events[0].event.myResponse == .accepted, "matched through the send-as alias")

        let previous = try await store.setMyResponse(accountID: F.me, messageID: "c1", response: .accepted)
        #expect(previous == nil)
        try await save(F.message(id: "c2", from: "Ada <ada@example.com>", subject: "Updated invitation", date: day(1), calendar: updated),
                       bucket: .calendar)
        let after = try await store.read { db in try MailStore.events(db, accountIDs: nil) }
        #expect(after[1].event.myResponse == .accepted, "an answer survives re-sync")
        #expect(try await store.setMyResponse(accountID: F.me, messageID: "c2", response: nil) == .accepted)
    }

    // MARK: - Observation

    @Test func observingUnreadCounts() async throws {
        var updates = store.observeUnreadCounts().makeAsyncIterator()
        #expect(try await updates.next()?[.newsletters] == 0)
        try await save(F.message(id: "n", from: "P <casey@platformer.news>", subject: "x"), bucket: .newsletters)
        var latest = try await updates.next()
        while latest?[.newsletters] == 0 { latest = try await updates.next() }
        #expect(latest?[.newsletters] == 1)
    }

    @Test func observingThreads() async throws {
        var updates = store.observeThreads(bucket: .notifications).makeAsyncIterator()
        #expect(try await updates.next()?.isEmpty == true)
        try await save(F.message(id: "g", from: "G <notifications@github.com>", subject: "x"), bucket: .notifications)
        var latest = try await updates.next()
        while latest?.isEmpty == true { latest = try await updates.next() }
        #expect(latest?.map(\.threadID) == ["g"])
        let starred = try await first(store.observeThreads(labelID: "STARRED")) { _ in true }
        #expect(starred == [])
    }

    @Test func notificationSourceKeys() {
        #expect(NotificationSource.key(listID: "dingo/dingo <dingo.dingo.github.com>", fromDomain: "github.com") == "dingo/dingo")
        #expect(NotificationSource.key(listID: "<my.repo.octo.github.com>", fromDomain: "github.com") == "octo/my.repo")
        #expect(NotificationSource.key(listID: "<team.linear.app>", fromDomain: "linear.app") == "linear.app")
        #expect(NotificationSource.key(listID: nil, fromDomain: "sentry.io") == "sentry.io")
    }
}
