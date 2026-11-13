import Foundation

/// The iTIP method of a calendar object (RFC 5546): what the sender wants done with the events.
public enum CalendarMethod: String, Codable, Sendable, CaseIterable {
    case publish = "PUBLISH", request = "REQUEST", reply = "REPLY", add = "ADD", cancel = "CANCEL"
    case refresh = "REFRESH", counter = "COUNTER", declineCounter = "DECLINECOUNTER"
}

/// An attendee's answer to an invitation (the PARTSTAT parameter).
public enum ParticipationStatus: String, Codable, Sendable, CaseIterable {
    case needsAction = "NEEDS-ACTION", accepted = "ACCEPTED", declined = "DECLINED"
    case tentative = "TENTATIVE", delegated = "DELEGATED"
}

/// One ATTENDEE line.
public struct CalendarAttendee: Codable, Hashable, Sendable {
    public var name: String?
    public var email: String
    public var status: ParticipationStatus
    /// REQ-PARTICIPANT, OPT-PARTICIPANT, CHAIR, NON-PARTICIPANT.
    public var role: String?
    public var rsvp: Bool

    public init(name: String? = nil, email: String, status: ParticipationStatus = .needsAction, role: String? = nil, rsvp: Bool = false) {
        self.name = name
        self.email = email
        self.status = status
        self.role = role
        self.rsvp = rsvp
    }

    enum CodingKeys: String, CodingKey {
        case name, email, status = "partstat", role, rsvp
    }
}

/// A parsed VCALENDAR: the method and its events.
public struct CalendarInvite: Sendable, Equatable {
    public var method: CalendarMethod
    public var events: [Event]

    /// The event an invite is about: the series master (no RECURRENCE-ID) when there is one.
    public var primaryEvent: Event? { events.first { $0.recurrenceID == nil } ?? events.first }

    public struct Event: Sendable, Equatable {
        public var uid: String
        public var sequence: Int
        public var summary: String?
        public var description: String?
        public var location: String?
        public var url: String?
        public var start: Date?
        public var end: Date?
        public var isAllDay: Bool
        /// The time zone the start and end were written in, as a Foundation identifier. Floating and
        /// all-day times carry the zone they were interpreted in, so a reply writes the same dates back.
        public var timeZone: String?
        public var organizer: EmailAddress?
        public var attendees: [CalendarAttendee]
        /// CONFIRMED, TENTATIVE, or CANCELLED.
        public var status: String?
        public var recurrenceID: String?
        public var recurrenceRule: String?

        public init(uid: String, sequence: Int = 0, summary: String? = nil, description: String? = nil, location: String? = nil,
                    url: String? = nil, start: Date? = nil, end: Date? = nil, isAllDay: Bool = false, timeZone: String? = nil,
                    organizer: EmailAddress? = nil, attendees: [CalendarAttendee] = [], status: String? = nil,
                    recurrenceID: String? = nil, recurrenceRule: String? = nil) {
            self.uid = uid
            self.sequence = sequence
            self.summary = summary
            self.description = description
            self.location = location
            self.url = url
            self.start = start
            self.end = end
            self.isAllDay = isAllDay
            self.timeZone = timeZone
            self.organizer = organizer
            self.attendees = attendees
            self.status = status
            self.recurrenceID = recurrenceID
            self.recurrenceRule = recurrenceRule
        }

        /// The attendee line for any of `addresses` (compared case-insensitively).
        public func attendee(matching addresses: Set<String>) -> CalendarAttendee? {
            attendees.first { addresses.contains($0.email.lowercased()) }
        }
    }
}

/// Reads the text/calendar parts that come with invitations (RFC 5545). It reads what mail clients
/// need to show and answer an invite; recurrence rules are kept as text, not expanded.
public enum ICalendarParser {
    /// Nil when the text holds no VCALENDAR. `defaultTimeZone` interprets floating times and all-day dates.
    public static func parse(_ text: String, defaultTimeZone: TimeZone = .current) -> CalendarInvite? {
        var method: CalendarMethod?
        var events: [CalendarInvite.Event] = []
        var stack: [String] = []
        var current: [ContentLine] = []
        var sawCalendar = false

        for line in unfold(text).compactMap(ContentLine.init) {
            switch line.name {
            case "BEGIN":
                let component = line.value.uppercased()
                stack.append(component)
                if component == "VCALENDAR" { sawCalendar = true }
                if component == "VEVENT" { current = [] }
            case "END":
                let component = line.value.uppercased()
                if component == "VEVENT", stack.last == "VEVENT",
                   let event = makeEvent(current, defaultTimeZone: defaultTimeZone) {
                    events.append(event)
                }
                if let index = stack.lastIndex(of: component) { stack.removeSubrange(index...) }
            default:
                if stack.last == "VEVENT" {
                    current.append(line)
                } else if stack.last == "VCALENDAR", line.name == "METHOD" {
                    method = CalendarMethod(rawValue: line.value.uppercased())
                }
            }
        }
        guard sawCalendar else { return nil }
        return CalendarInvite(method: method ?? .publish, events: events)
    }

    // MARK: - Content lines

    /// Joins folded lines: a line break followed by one space or tab continues the previous line.
    static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else {
                lines.append(String(raw.replacingOccurrences(of: "\r", with: "")))
            }
        }
        return lines.filter { !$0.isEmpty }
    }

    /// `NAME;PARAM=value;PARAM="quoted, value":value`.
    struct ContentLine {
        var name: String
        var parameters: [String: String]
        var value: String

        init?(_ line: String) {
            var name = ""
            var parameters: [String: String] = [:]
            var index = line.startIndex
            // Name runs to the first ; or :.
            while index < line.endIndex, line[index] != ";", line[index] != ":" {
                name.append(line[index])
                index = line.index(after: index)
            }
            guard index < line.endIndex, !name.isEmpty else { return nil }
            while index < line.endIndex, line[index] == ";" {
                index = line.index(after: index)
                var key = ""
                while index < line.endIndex, line[index] != "=", line[index] != ":", line[index] != ";" {
                    key.append(line[index])
                    index = line.index(after: index)
                }
                var value = ""
                if index < line.endIndex, line[index] == "=" {
                    index = line.index(after: index)
                    var quoted = false
                    while index < line.endIndex {
                        let c = line[index]
                        if c == "\"" { quoted.toggle() }
                        else if !quoted, c == ";" || c == ":" { break }
                        else { value.append(c) }
                        index = line.index(after: index)
                    }
                }
                parameters[key.uppercased()] = value
            }
            guard index < line.endIndex, line[index] == ":" else { return nil }
            self.name = name.uppercased()
            self.parameters = parameters
            self.value = String(line[line.index(after: index)...])
        }
    }

    // MARK: - Events

    static func makeEvent(_ lines: [ContentLine], defaultTimeZone: TimeZone) -> CalendarInvite.Event? {
        func first(_ name: String) -> ContentLine? { lines.first { $0.name == name } }
        guard let uid = first("UID")?.value, !uid.isEmpty else { return nil }

        var event = CalendarInvite.Event(uid: uid)
        event.sequence = first("SEQUENCE").flatMap { Int($0.value.trimmingCharacters(in: .whitespaces)) } ?? 0
        event.summary = first("SUMMARY").map { unescape($0.value) }
        event.description = first("DESCRIPTION").map { unescape($0.value) }
        event.location = first("LOCATION").map { unescape($0.value) }.flatMap { $0.isEmpty ? nil : $0 }
        event.url = first("URL")?.value
        event.status = first("STATUS")?.value.uppercased()
        event.recurrenceID = first("RECURRENCE-ID")?.value
        event.recurrenceRule = first("RRULE")?.value
        event.organizer = first("ORGANIZER").map { EmailAddress(name: $0.parameters["CN"], email: mailto($0.value)) }
        event.attendees = lines.filter { $0.name == "ATTENDEE" }.map { line in
            CalendarAttendee(name: line.parameters["CN"], email: mailto(line.value),
                             status: line.parameters["PARTSTAT"].flatMap { ParticipationStatus(rawValue: $0.uppercased()) } ?? .needsAction,
                             role: line.parameters["ROLE"]?.uppercased(),
                             rsvp: line.parameters["RSVP"]?.uppercased() == "TRUE")
        }

        if let dtstart = first("DTSTART"), let start = parseDate(dtstart, defaultTimeZone: defaultTimeZone) {
            event.start = start.date
            event.isAllDay = start.isAllDay
            event.timeZone = start.timeZone.identifier
            if let dtend = first("DTEND"), let end = parseDate(dtend, defaultTimeZone: defaultTimeZone) {
                event.end = end.date
            } else if let duration = first("DURATION").flatMap({ parseDuration($0.value) }) {
                event.end = start.date.addingTimeInterval(duration)
            } else if start.isAllDay {
                // RFC 5545 3.6.1: an all-day event without an end lasts the one day.
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = start.timeZone
                event.end = calendar.date(byAdding: .day, value: 1, to: start.date)
            } else {
                event.end = start.date
            }
        }
        return event
    }

    static func mailto(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.lowercased().hasPrefix("mailto:") ? String(trimmed.dropFirst(7)) : trimmed
    }

    /// TEXT values escape backslash, semicolon, comma, and newline.
    static func unescape(_ value: String) -> String {
        var result = ""
        var escaping = false
        for c in value {
            if escaping {
                switch c {
                case "n", "N": result.append("\n")
                default: result.append(c)
                }
                escaping = false
            } else if c == "\\" {
                escaping = true
            } else {
                result.append(c)
            }
        }
        return result
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    // MARK: - Dates

    struct ParsedDate {
        var date: Date
        var isAllDay: Bool
        var timeZone: TimeZone
    }

    /// DATE-TIME in UTC (`Z`), with a TZID, or floating; or a DATE (`VALUE=DATE`) for all-day events.
    static func parseDate(_ line: ContentLine, defaultTimeZone: TimeZone) -> ParsedDate? {
        let value = line.value.trimmingCharacters(in: .whitespaces)
        let digits = value.filter(\.isNumber)
        let isDate = line.parameters["VALUE"]?.uppercased() == "DATE" || (digits.count == 8 && !value.contains("T"))
        let timeZone: TimeZone
        if value.hasSuffix("Z") || value.hasSuffix("z") {
            timeZone = TimeZone(identifier: "UTC")!
        } else if !isDate, let tzid = line.parameters["TZID"] {
            timeZone = Self.timeZone(tzid) ?? defaultTimeZone
        } else {
            timeZone = defaultTimeZone
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let chars = Array(digits)
        func number(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= chars.count else { return nil }
            return Int(String(chars[range]))
        }
        guard let year = number(0..<4), let month = number(4..<6), let day = number(6..<8) else { return nil }
        var components = DateComponents(year: year, month: month, day: day)
        if !isDate {
            guard let hour = number(8..<10), let minute = number(10..<12) else { return nil }
            components.hour = hour
            components.minute = minute
            components.second = number(12..<14) ?? 0
        }
        guard let date = calendar.date(from: components) else { return nil }
        return ParsedDate(date: date, isAllDay: isDate, timeZone: timeZone)
    }

    /// `P1W`, `P1DT2H`, `PT45M`, `-PT15M`.
    static func parseDuration(_ value: String) -> TimeInterval? {
        var text = Substring(value.trimmingCharacters(in: .whitespaces).uppercased())
        var sign = 1.0
        if text.first == "-" { sign = -1; text = text.dropFirst() } else if text.first == "+" { text = text.dropFirst() }
        guard text.first == "P" else { return nil }
        text = text.dropFirst()
        var total = 0.0
        var number = ""
        for c in text {
            if c.isNumber { number.append(c); continue }
            if c == "T" { continue }
            guard let n = Double(number) else { return nil }
            switch c {
            case "W": total += n * 604_800
            case "D": total += n * 86_400
            case "H": total += n * 3_600
            case "M": total += n * 60
            case "S": total += n
            default: return nil
            }
            number = ""
        }
        return sign * total
    }

    /// Resolves a TZID. Google writes IANA names; Outlook writes Windows names ("Pacific Standard
    /// Time") or display names ("(UTC-08:00) Pacific Time (US & Canada)"); some clients prefix a
    /// vendor path ("/mozilla.org/20050126_1/America/New_York").
    static func timeZone(_ tzid: String) -> TimeZone? {
        let name = tzid.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        if let zone = TimeZone(identifier: name) { return zone }
        if let mapped = windowsZones[name] { return TimeZone(identifier: mapped) }
        let parts = name.split(separator: "/")
        for start in parts.indices.dropFirst() {
            if let zone = TimeZone(identifier: parts[start...].joined(separator: "/")) { return zone }
        }
        let lowered = name.lowercased()
        if let match = displayNameZones.first(where: { lowered.contains($0.key) }) { return TimeZone(identifier: match.value) }
        return nil
    }

    /// The Windows zone names Exchange and Outlook use most, mapped to IANA ids (from CLDR windowsZones).
    static let windowsZones: [String: String] = [
        "Dateline Standard Time": "Etc/GMT+12",
        "Hawaiian Standard Time": "Pacific/Honolulu",
        "Alaskan Standard Time": "America/Anchorage",
        "Pacific Standard Time": "America/Los_Angeles",
        "Pacific Standard Time (Mexico)": "America/Tijuana",
        "US Mountain Standard Time": "America/Phoenix",
        "Mountain Standard Time": "America/Denver",
        "Central Standard Time": "America/Chicago",
        "Central Standard Time (Mexico)": "America/Mexico_City",
        "Canada Central Standard Time": "America/Regina",
        "Eastern Standard Time": "America/New_York",
        "US Eastern Standard Time": "America/Indianapolis",
        "SA Pacific Standard Time": "America/Bogota",
        "Atlantic Standard Time": "America/Halifax",
        "Newfoundland Standard Time": "America/St_Johns",
        "E. South America Standard Time": "America/Sao_Paulo",
        "Argentina Standard Time": "America/Buenos_Aires",
        "UTC": "UTC",
        "GMT Standard Time": "Europe/London",
        "Greenwich Standard Time": "Atlantic/Reykjavik",
        "W. Europe Standard Time": "Europe/Berlin",
        "Romance Standard Time": "Europe/Paris",
        "Central Europe Standard Time": "Europe/Budapest",
        "Central European Standard Time": "Europe/Warsaw",
        "E. Europe Standard Time": "Europe/Chisinau",
        "FLE Standard Time": "Europe/Kiev",
        "GTB Standard Time": "Europe/Bucharest",
        "Turkey Standard Time": "Europe/Istanbul",
        "Israel Standard Time": "Asia/Jerusalem",
        "South Africa Standard Time": "Africa/Johannesburg",
        "Russian Standard Time": "Europe/Moscow",
        "Arabian Standard Time": "Asia/Dubai",
        "India Standard Time": "Asia/Calcutta",
        "SE Asia Standard Time": "Asia/Bangkok",
        "China Standard Time": "Asia/Shanghai",
        "Singapore Standard Time": "Asia/Singapore",
        "Taipei Standard Time": "Asia/Taipei",
        "Tokyo Standard Time": "Asia/Tokyo",
        "Korea Standard Time": "Asia/Seoul",
        "W. Australia Standard Time": "Australia/Perth",
        "Cen. Australia Standard Time": "Australia/Adelaide",
        "E. Australia Standard Time": "Australia/Brisbane",
        "AUS Eastern Standard Time": "Australia/Sydney",
        "New Zealand Standard Time": "Pacific/Auckland",
    ]

    static let displayNameZones: [String: String] = [
        "pacific time": "America/Los_Angeles",
        "mountain time": "America/Denver",
        "arizona": "America/Phoenix",
        "central time": "America/Chicago",
        "eastern time": "America/New_York",
    ]
}

/// Builds the iMIP REPLY (RFC 6047) Dingo sends when the user answers an invitation. The organizer's
/// calendar matches it to the event by UID and SEQUENCE and records the one attendee's PARTSTAT.
public enum IMIPReply {
    public enum Response: String, Sendable, CaseIterable {
        case accepted, tentative, declined

        public var status: ParticipationStatus {
            switch self {
            case .accepted: .accepted
            case .tentative: .tentative
            case .declined: .declined
            }
        }
    }

    public static func make(event: CalendarInvite.Event, attendee: EmailAddress, response: Response, now: Date = Date()) -> String {
        let zone = event.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        var lines = [
            "BEGIN:VCALENDAR",
            "PRODID:-//Dingo//EN",
            "VERSION:2.0",
            "CALSCALE:GREGORIAN",
            "METHOD:REPLY",
            "BEGIN:VEVENT",
        ]
        if let start = event.start { lines.append(dateLine("DTSTART", start, allDay: event.isAllDay, zone: zone)) }
        if let end = event.end { lines.append(dateLine("DTEND", end, allDay: event.isAllDay, zone: zone)) }
        lines.append("DTSTAMP:" + utcStamp(now))
        if let organizer = event.organizer {
            lines.append("ORGANIZER" + cn(organizer.name) + ":mailto:" + organizer.email)
        }
        lines.append("UID:" + event.uid)
        if let recurrenceID = event.recurrenceID { lines.append("RECURRENCE-ID:" + recurrenceID) }
        lines.append("SEQUENCE:\(event.sequence)")
        let name = attendee.name ?? event.attendees.first { $0.email.caseInsensitiveCompare(attendee.email) == .orderedSame }?.name
        lines.append("ATTENDEE" + cn(name) + ";PARTSTAT=\(response.status.rawValue):mailto:" + attendee.email)
        if let summary = event.summary { lines.append("SUMMARY:" + ICalendarParser.escape(summary)) }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    /// Parameter values with , ; or : must be quoted; quotes themselves cannot appear (RFC 5545 3.2).
    static func cn(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "" }
        return ";CN=\"" + name.replacingOccurrences(of: "\"", with: "'") + "\""
    }

    static func dateLine(_ name: String, _ date: Date, allDay: Bool, zone: TimeZone) -> String {
        guard allDay else { return name + ":" + utcStamp(date) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return name + ";VALUE=DATE:" + String(format: "%04d%02d%02d", c.year!, c.month!, c.day!)
    }

    static func utcStamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    /// Lines longer than 75 octets continue on lines that start with a space (RFC 5545 3.1),
    /// splitting between characters so no UTF-8 sequence is broken.
    static func fold(_ line: String) -> String {
        var result = ""
        var count = 0
        for character in line {
            let size = character.utf8.count
            if count + size > 75 {
                result += "\r\n "
                count = 1
            }
            result.append(character)
            count += size
        }
        return result
    }
}
