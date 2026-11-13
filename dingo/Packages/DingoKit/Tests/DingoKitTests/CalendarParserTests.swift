import Foundation
import Testing
@testable import DingoKit

@Suite struct CalendarParserTests {
    typealias F = BucketFixtures

    static let utc = TimeZone(identifier: "UTC")!
    static let pacific = TimeZone(identifier: "America/Los_Angeles")!

    func date(_ string: String) -> Date {
        try! Date(string, strategy: .iso8601)
    }

    @Test func googleInvite() throws {
        let invite = try #require(ICalendarParser.parse(try F.fixture("google-invite.ics"), defaultTimeZone: Self.utc))
        #expect(invite.method == .request)
        let event = try #require(invite.primaryEvent)
        #expect(event.uid == "7kukuqrfedlm2f9t2vr8bk2bde@google.com")
        #expect(event.sequence == 0)
        #expect(event.summary == "Dingo design review")
        #expect(event.location == "Room 4, Building 2")
        #expect(event.description == "Agenda:\n1. Buckets, labels; sync\n\nJoin with Google Meet: https://meet.google.com/abc-defg-hij")
        #expect(event.start == date("2026-11-18T17:00:00Z"))
        #expect(event.end == date("2026-11-18T17:30:00Z"))
        #expect(event.timeZone == "America/Los_Angeles")
        #expect(!event.isAllDay)
        #expect(event.organizer == EmailAddress(name: "Ada Lovelace", email: "ada@example.com"))
        #expect(event.attendees.count == 2)
        #expect(event.attendees[0] == CalendarAttendee(name: "Ada Lovelace", email: "ada@example.com", status: .accepted,
                                                       role: "REQ-PARTICIPANT", rsvp: true))
        #expect(event.attendee(matching: ["me@example.org"])?.status == .needsAction)
    }

    @Test func outlookInviteWithWindowsZone() throws {
        let invite = try #require(ICalendarParser.parse(try F.fixture("outlook-invite.ics"), defaultTimeZone: Self.utc))
        let event = try #require(invite.primaryEvent)
        #expect(event.uid == "040000008200E00074C5B7101A82E00800000000D0F7B8E2B4C9DA01000000000000000010000000A1B2C3D4E5F60718293A4B5C6D7E8F")
        #expect(event.sequence == 2)
        #expect(event.summary == "Q1 planning")
        #expect(event.timeZone == "America/Los_Angeles")
        #expect(event.start == date("2026-12-03T18:00:00Z"))
        #expect(event.end == date("2026-12-03T19:30:00Z"))
        #expect(event.organizer?.name == "Grace Hopper")
        #expect(event.attendees[0].name == "Doe, Jane")
        #expect(event.attendees[1].email == "me@example.org")
        #expect(event.attendees[1].status == .tentative)
        #expect(event.attendees[1].role == "OPT-PARTICIPANT")
    }

    @Test(arguments: [
        ("Pacific Standard Time", "America/Los_Angeles"),
        ("Eastern Standard Time", "America/New_York"),
        ("W. Europe Standard Time", "Europe/Berlin"),
        ("(UTC-08:00) Pacific Time (US & Canada)", "America/Los_Angeles"),
        ("/mozilla.org/20050126_1/America/New_York", "America/New_York"),
        ("Europe/London", "Europe/London"),
    ])
    func timeZoneNames(tzid: String, identifier: String) {
        #expect(ICalendarParser.timeZone(tzid) == TimeZone(identifier: identifier))
    }

    @Test func allDayEvent() throws {
        let invite = try #require(ICalendarParser.parse(try F.fixture("all-day.ics"), defaultTimeZone: Self.pacific))
        #expect(invite.method == .publish)
        let event = try #require(invite.primaryEvent)
        #expect(event.isAllDay)
        #expect(event.timeZone == "America/Los_Angeles")
        #expect(event.start == date("2026-12-24T08:00:00Z"))
        #expect(event.end == date("2026-12-26T08:00:00Z"))
    }

    @Test func durationAndFloatingTimes() throws {
        let text = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:d1\nDTSTART:20261120T090000\nDURATION:PT1H30M\nEND:VEVENT\nEND:VCALENDAR\n"
        let event = try #require(ICalendarParser.parse(text, defaultTimeZone: Self.pacific)?.primaryEvent)
        #expect(event.start == date("2026-11-20T17:00:00Z"))
        #expect(event.end == date("2026-11-20T18:30:00Z"))
        #expect(ICalendarParser.parseDuration("P1W") == 604_800)
        #expect(ICalendarParser.parseDuration("P1DT2H") == 93_600)
        #expect(ICalendarParser.parseDuration("-PT15M") == -900)
    }

    @Test func allDayWithoutEndLastsOneDay() throws {
        let text = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:d2\nDTSTART;VALUE=DATE:20261201\nEND:VEVENT\nEND:VCALENDAR\n"
        let event = try #require(ICalendarParser.parse(text, defaultTimeZone: Self.utc)?.primaryEvent)
        #expect(event.end == date("2026-12-02T00:00:00Z"))
    }

    @Test func notACalendar() {
        #expect(ICalendarParser.parse("hello") == nil)
    }

    @Test func seriesMasterIsPrimary() throws {
        let text = """
            BEGIN:VCALENDAR\nMETHOD:REQUEST\nBEGIN:VEVENT\nUID:s\nRECURRENCE-ID:20261125T170000Z\nSUMMARY:Moved\nEND:VEVENT
            BEGIN:VEVENT\nUID:s\nRRULE:FREQ=WEEKLY\nSUMMARY:Weekly\nEND:VEVENT\nEND:VCALENDAR
            """
        let invite = try #require(ICalendarParser.parse(text))
        #expect(invite.events.count == 2)
        #expect(invite.primaryEvent?.summary == "Weekly")
        #expect(invite.primaryEvent?.recurrenceRule == "FREQ=WEEKLY")
    }

    // MARK: - iMIP reply

    @Test func replyRoundTrip() throws {
        let invite = try #require(ICalendarParser.parse(try F.fixture("outlook-invite.ics"), defaultTimeZone: Self.utc))
        let event = try #require(invite.primaryEvent)
        let now = date("2026-11-11T20:00:00Z")
        let reply = IMIPReply.make(event: event, attendee: EmailAddress(email: "me@example.org"), response: .accepted, now: now)

        #expect(reply.hasSuffix("\r\n"))
        #expect(!reply.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        for line in reply.components(separatedBy: "\r\n") { #expect(line.utf8.count <= 75, "\(line)") }
        #expect(reply.contains("PRODID:-//Dingo//EN\r\n"))
        #expect(reply.contains("DTSTAMP:20261111T200000Z\r\n"))

        let parsed = try #require(ICalendarParser.parse(reply, defaultTimeZone: Self.utc))
        #expect(parsed.method == .reply)
        let answered = try #require(parsed.primaryEvent)
        #expect(answered.uid == event.uid)
        #expect(answered.sequence == 2)
        #expect(answered.start == event.start)
        #expect(answered.end == event.end)
        #expect(answered.summary == "Q1 planning")
        #expect(answered.organizer?.email == "grace@contoso.com")
        #expect(answered.attendees == [CalendarAttendee(name: "me@example.org", email: "me@example.org", status: .accepted)])
    }

    @Test func replyForAllDayKeepsDates() throws {
        let invite = try #require(ICalendarParser.parse(try F.fixture("all-day.ics"), defaultTimeZone: Self.pacific))
        let event = try #require(invite.primaryEvent)
        let reply = IMIPReply.make(event: event, attendee: EmailAddress(name: "Me", email: "me@example.org"), response: .declined)
        #expect(reply.contains("DTSTART;VALUE=DATE:20261224\r\n"))
        #expect(reply.contains("DTEND;VALUE=DATE:20261226\r\n"))
        #expect(reply.contains("ATTENDEE;CN=\"Me\";PARTSTAT=DECLINED:mailto:me@example.org\r\n"))
        let answered = try #require(ICalendarParser.parse(reply, defaultTimeZone: Self.pacific)?.primaryEvent)
        #expect(answered.start == event.start && answered.isAllDay)
    }

    @Test func foldingKeepsCharactersWhole() {
        let summary = String(repeating: "日本語", count: 20)
        let event = CalendarInvite.Event(uid: "f", summary: summary, start: date("2026-11-20T17:00:00Z"), timeZone: "UTC")
        let reply = IMIPReply.make(event: event, attendee: EmailAddress(email: "me@example.org"), response: .tentative)
        for line in reply.components(separatedBy: "\r\n") { #expect(line.utf8.count <= 75) }
        #expect(ICalendarParser.parse(reply)?.primaryEvent?.summary == summary)
        #expect(reply.contains("PARTSTAT=TENTATIVE"))
    }
}
