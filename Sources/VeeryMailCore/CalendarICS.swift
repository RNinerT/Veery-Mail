import Foundation

/// iCalendar encoding for new events and decoding of the instances expanded by CalDAV.
enum CalendarICS {
    private struct Property {
        let name: String
        let parameters: [String]
        let value: String

        init?(_ line: String) {
            var quoted = false
            guard let separator = line.firstIndex(where: { character in
                if character == "\"" { quoted.toggle() }
                return character == ":" && !quoted
            }) else { return nil }
            let parts = line[..<separator].split(separator: ";").map(String.init)
            guard let first = parts.first else { return nil }
            name = first.uppercased()
            parameters = Array(parts.dropFirst())
            value = String(line[line.index(after: separator)...])
        }

        var allDay: Bool { value.count == 8 && !value.contains("T") }

        func timestamp(calendar: Calendar) -> Date? {
            let timeZoneID = parameters.first { $0.uppercased().hasPrefix("TZID=") }
                .map { $0.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            let zone: TimeZone
            if value.hasSuffix("Z") { zone = TimeZone(secondsFromGMT: 0)! }
            else if let timeZoneID {
                guard let explicit = TimeZone(identifier: timeZoneID) else { return nil }
                zone = explicit
            } else { zone = calendar.timeZone }
            let format = allDay ? "yyyyMMdd" : (value.hasSuffix("Z") ? "yyyyMMdd'T'HHmmss'Z'" : "yyyyMMdd'T'HHmmss")
            return CalendarICS.formatter(format, zone: zone).date(from: value)
        }
    }

    static func events(_ content: String, calendar: Calendar) -> [FastmailCalendarEvent] {
        var lines: [String] = []
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for line in normalized.components(separatedBy: "\n") {
            if line.first == " " || line.first == "\t", !lines.isEmpty {
                lines[lines.count - 1].append(contentsOf: line.dropFirst())
            } else { lines.append(line) }
        }
        var result: [FastmailCalendarEvent] = []
        var components: [String] = []
        var event: [String: Property] = [:]
        for line in lines {
            guard let property = Property(line) else { continue }
            switch property.name {
            case "BEGIN":
                if property.value.uppercased() == "VEVENT" { event = [:] }
                components.append(property.value.uppercased())
            case "END":
                guard components.last == property.value.uppercased() else { continue }
                if components.removeLast() == "VEVENT", let instance = instance(event, calendar: calendar) {
                    result.append(instance)
                }
            default:
                if components.last == "VEVENT" { event[property.name] = property }
            }
        }
        return result
    }

    private static func instance(_ event: [String: Property], calendar: Calendar) -> FastmailCalendarEvent? {
        guard event["STATUS"]?.value.uppercased() != "CANCELLED",
              let uid = event["UID"]?.value, let start = event["DTSTART"],
              let begins = start.timestamp(calendar: calendar) else { return nil }
        let end: Date
        if let property = event["DTEND"] {
            guard let parsed = property.timestamp(calendar: calendar) else { return nil }
            end = parsed
        } else if let value = event["DURATION"]?.value {
            guard let parsed = addingDuration(value, to: begins, calendar: calendar) else { return nil }
            end = parsed
        } else {
            end = start.allDay ? calendar.date(byAdding: .day, value: 1, to: begins) ?? begins : begins
        }
        return FastmailCalendarEvent(id: uid + ":" + (event["RECURRENCE-ID"]?.value ?? start.value),
                                     uid: uid, title: event["SUMMARY"].map { unescape($0.value) } ?? "Untitled Event",
                                     start: begins, end: end, allDay: start.allDay,
                                     location: event["LOCATION"].map { unescape($0.value) },
                                     notes: event["DESCRIPTION"].map { unescape($0.value) })
    }

    private static func addingDuration(_ value: String, to date: Date, calendar: Calendar) -> Date? {
        guard value.first == "P" else { return nil }
        var count = ""
        var days = 0
        var seconds = 0
        for unit in value.dropFirst() {
            if unit == "T", count.isEmpty { continue }
            if unit.isASCII && unit.isNumber { count.append(unit); continue }
            guard let number = Int(count), number <= 1_000_000 else { return nil }
            switch unit {
            case "W": days += number * 7
            case "D": days += number
            case "H": seconds += number * 3600
            case "M": seconds += number * 60
            case "S": seconds += number
            default: return nil
            }
            count = ""
        }
        guard count.isEmpty else { return nil }
        return calendar.date(byAdding: .day, value: days, to: date)?.addingTimeInterval(TimeInterval(seconds))
    }

    static func encode(_ event: CalendarEventInput, uid: String, calendar: Calendar) -> String {
        let allDayFormat = formatter("yyyyMMdd", zone: calendar.timeZone)
        let start = event.allDay ? "DTSTART;VALUE=DATE:\(allDayFormat.string(from: event.start))" : "DTSTART:\(utc(event.start))"
        let end = event.allDay ? "DTEND;VALUE=DATE:\(allDayFormat.string(from: event.end))" : "DTEND:\(utc(event.end))"
        let lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Veery Mail//Calendar//EN", "BEGIN:VEVENT",
                     "UID:\(uid)", "DTSTAMP:\(utc(Date()))", start, end, "SUMMARY:\(escape(event.title))",
                     "LOCATION:\(escape(event.location))", "DESCRIPTION:\(escape(event.notes))",
                     "END:VEVENT", "END:VCALENDAR"]
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    static func utc(_ date: Date) -> String {
        formatter("yyyyMMdd'T'HHmmss'Z'", zone: TimeZone(secondsFromGMT: 0)!).string(from: date)
    }

    private static func formatter(_ format: String, zone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = format
        return formatter
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: ";", with: "\\;")
    }

    private static func unescape(_ value: String) -> String {
        var result = ""
        var escaped = false
        for character in value {
            if escaped {
                result.append(character == "n" || character == "N" ? "\n" : character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else { result.append(character) }
        }
        if escaped { result.append("\\") }
        return result
    }

    private static func fold(_ line: String) -> String {
        var result = ""
        var bytes = 0
        for scalar in line.unicodeScalars {
            let size = scalar.utf8.count
            if bytes + size > 75 {
                result += "\r\n "
                bytes = 1
            }
            result.unicodeScalars.append(scalar)
            bytes += size
        }
        return result
    }
}
