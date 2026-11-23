import Foundation

public enum CalendarDisplay: String, CaseIterable, Sendable {
    case agenda, day, threeDays, month, ninetyDays

    public var title: String {
        switch self {
        case .agenda: return "List"
        case .day: return "1 Day"
        case .threeDays: return "3 Days"
        case .month: return "Month"
        case .ninetyDays: return "90 Days"
        }
    }

    private var dayCount: Int {
        switch self {
        case .agenda: return 8
        case .day: return 1
        case .threeDays: return 3
        case .month: return 0
        case .ninetyDays: return 90
        }
    }

    public func range(containing date: Date, calendar: Calendar) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        if self == .month, let month = calendar.dateInterval(of: .month, for: start) { return month }
        return DateInterval(start: start, end: calendar.date(byAdding: .day, value: max(dayCount, 1), to: start) ?? start)
    }

    public func page(from date: Date, direction: Int, calendar: Calendar) -> Date {
        let start = range(containing: date, calendar: calendar).start
        let step = self == .agenda ? 1 : max(dayCount, 1)
        return calendar.date(byAdding: self == .month ? .month : .day, value: direction * step, to: start) ?? date
    }

    public static func days(in interval: DateInterval, calendar: Calendar) -> [Date] {
        var days: [Date] = []
        var day = calendar.startOfDay(for: interval.start)
        while day < interval.end, let next = calendar.date(byAdding: .day, value: 1, to: day), next > day {
            days.append(day)
            day = next
        }
        return days
    }
}
