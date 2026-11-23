import SwiftUI

struct CalendarGridDay: Identifiable {
    let date: Date
    let events: [AgendaEvent]
    var id: Date { date }
}

struct CalendarTimeGrid: View {
    let days: [CalendarGridDay]
    let calendar: Calendar
    let openEvent: (AgendaEvent) -> Void

    private let hourHeight: CGFloat = 54
    private let timeWidth: CGFloat = 58
    private let hours = 0..<24
    private let hourFormat = Date.FormatStyle(timeZone: TimeZone(secondsFromGMT: 0)!).hour()

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Text("All Day")
                    .font(.caption)
                    .foregroundStyle(WorkspacePaper.secondary)
                    .frame(width: timeWidth, alignment: .trailing)
                    .padding(.top, 38)
                    .padding(.trailing, 8)
                ForEach(days) { day in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(day.date, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(calendar.isDateInToday(day.date) ? WorkspacePaper.accent : WorkspacePaper.ink)
                            .lineLimit(1)
                            .padding(.bottom, 3)
                            .accessibilityAddTraits(.isHeader)
                        let allDay = day.events.filter(\.allDay)
                        ForEach(allDay.prefix(3)) { event in
                            eventButton(event, showTime: false)
                        }
                        if allDay.count > 3 {
                            Menu("+\(allDay.count - 3) more") {
                                ForEach(allDay.dropFirst(3)) { event in
                                    Button(event.title) { openEvent(event) }
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            ForEach(hours, id: \.self) { hour in
                                hourLine(hour)
                                    .frame(height: hourHeight, alignment: .top)
                                    .id(hour)
                            }
                        }
                        HStack(spacing: 0) {
                            Color.clear.frame(width: timeWidth + 8)
                            ForEach(days) { day in dayColumn(day) }
                        }
                    }
                    .padding(.top, 6)
                }
                .onAppear { proxy.scrollTo(8, anchor: .top) }
            }
        }
        .padding(.horizontal, 16)
    }

    private func hourLine(_ hour: Int) -> some View {
        let time = Date(timeIntervalSince1970: Double(hour) * 3600)
        return HStack(alignment: .top, spacing: 8) {
            Text(time, format: hourFormat)
                .font(.caption.monospacedDigit())
                .foregroundStyle(WorkspacePaper.secondary)
                .frame(width: timeWidth, alignment: .trailing)
            Rectangle().fill(WorkspacePaper.ink.opacity(0.10)).frame(height: 1)
                .padding(.top, 4)
        }
        .accessibilityHidden(true)
    }

    private func dayColumn(_ day: CalendarGridDay) -> some View {
        let layout = timedLayout(day)
        return GeometryReader { geometry in
            let laneWidth = max(1, (geometry.size.width - 4) / CGFloat(layout.width))
            ZStack(alignment: .topLeading) {
                Rectangle().fill(WorkspacePaper.ink.opacity(0.10)).frame(width: 1)
                ForEach(layout.items) { item in
                    let height = hourHeight * (item.end - item.start) / 60
                    eventButton(item.event, showTime: height >= 38, height: max(1, height - 2))
                        .frame(width: max(1, laneWidth - 3), alignment: .topLeading)
                        .clipped()
                        .offset(x: 3 + CGFloat(item.lane) * laneWidth, y: 4 + hourHeight * item.start / 60)
                }
            }
        }
        .frame(height: CGFloat(hours.count) * hourHeight)
    }

    private func eventButton(_ event: AgendaEvent, showTime: Bool, height: CGFloat? = nil) -> some View {
        Button { openEvent(event) } label: {
            VStack(alignment: .leading, spacing: 1) {
                if showTime {
                    Text(event.start, format: .dateTime.hour().minute())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(WorkspacePaper.secondary)
                }
                Text(event.title).font(.caption.weight(.medium)).lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height, alignment: .topLeading)
            .background(event.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .leading) {
                Capsule().fill(event.color).frame(width: 2).padding(.vertical, 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(event.title)
        .accessibilityLabel(event.allDay ? "All day, \(event.title)" :
            "\(event.start.formatted(date: .omitted, time: .shortened)), \(event.title)")
    }

    private struct TimedItem: Identifiable {
        let event: AgendaEvent
        let lane: Int
        let start, end: CGFloat
        var id: String { event.id }
    }

    private func timedLayout(_ day: CalendarGridDay) -> (items: [TimedItem], width: Int) {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: day.date) ?? day.date
        func minutes(_ date: Date) -> CGFloat {
            let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
            return CGFloat((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) + CGFloat(parts.second ?? 0) / 60
        }
        let spans = day.events.filter { !$0.allDay }.map { event in
            let start = event.start <= day.date ? 0 : min(1416, minutes(event.start))
            let end = event.end >= tomorrow ? 1440 : max(start + 24, minutes(event.end))
            return (event: event, start: start, end: min(1440, end))
        }.sorted {
            if $0.start == $1.start { return $0.end > $1.end }
            return $0.start < $1.start
        }
        var laneEnds: [CGFloat] = []
        let items = spans.map { span in
            let lane = laneEnds.firstIndex(where: { $0 <= span.start }) ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(span.end) }
            else { laneEnds[lane] = span.end }
            return TimedItem(event: span.event, lane: lane, start: span.start, end: span.end)
        }
        return (items, max(1, laneEnds.count))
    }
}

struct CalendarDateGrid: View {
    let days: [CalendarGridDay]
    let calendar: Calendar
    let compact: Bool
    let openDay: (Date) -> Void
    let openEvent: (AgendaEvent) -> Void

    private let columns = Array(repeating: GridItem(.flexible(minimum: 35), spacing: 4), count: 7)
    private let weekdays = 0..<7

    private var leading: Int {
        guard let start = days.first?.date else { return 0 }
        return (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
    }

    var body: some View {
        VStack(spacing: 4) {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(weekdays, id: \.self) { index in
                    Text(calendar.shortStandaloneWeekdaySymbols[(calendar.firstWeekday - 1 + index) % 7])
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WorkspacePaper.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 8)
                }
            }
            .accessibilityHidden(true)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(0..<leading, id: \.self) { _ in Color.clear.frame(height: cardHeight) }
                    ForEach(days) { day in
                        if compact { overviewDay(day) }
                        else { monthDay(day) }
                    }
                }
            }
        }
        .padding(16)
    }

    private var cardHeight: CGFloat { compact ? 50 : 92 }

    private func monthDay(_ day: CalendarGridDay) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Button { openDay(day.date) } label: {
                dayNumber(day.date, full: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(day.date.formatted(date: .complete, time: .omitted))
            ForEach(day.events.prefix(2)) { event in
                Button { openEvent(event) } label: {
                    HStack(spacing: 4) {
                        Circle().fill(event.color).frame(width: 5, height: 5)
                        Text(event.title).font(.caption).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(event.title)
            }
            if day.events.count > 2 {
                Button("+\(day.events.count - 2) more") { openDay(day.date) }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(WorkspacePaper.accent)
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: cardHeight, alignment: .topLeading)
        .background(cellBackground(day.date), in: RoundedRectangle(cornerRadius: 6))
    }

    private func overviewDay(_ day: CalendarGridDay) -> some View {
        Button { openDay(day.date) } label: {
            VStack(alignment: .leading, spacing: 4) {
                dayNumber(day.date, full: day.id == days.first?.id || calendar.component(.day, from: day.date) == 1)
                if !day.events.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(day.events.prefix(3)) { event in
                            Circle().fill(event.color).frame(width: 5, height: 5)
                        }
                        if day.events.count > 3 { Text("\(day.events.count)").font(.caption2.monospacedDigit()) }
                    }
                }
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: cardHeight, alignment: .topLeading)
            .background(cellBackground(day.date), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(day.date.formatted(date: .complete, time: .omitted)), \(day.events.count) events")
    }

    private func dayNumber(_ date: Date, full: Bool) -> some View {
        let today = calendar.isDateInToday(date)
        return Text(full ? date.formatted(.dateTime.month(.abbreviated).day()) : date.formatted(.dateTime.day()))
            .font(.caption.weight(today ? .bold : .semibold))
            .foregroundStyle(today ? WorkspacePaper.accent : WorkspacePaper.ink)
            .lineLimit(1)
    }

    private func cellBackground(_ date: Date) -> Color {
        calendar.isDateInToday(date) ? WorkspacePaper.accent.opacity(0.12) : WorkspacePaper.ink.opacity(0.045)
    }
}
