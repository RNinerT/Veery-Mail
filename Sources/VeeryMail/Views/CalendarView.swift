import AppKit
import EventKit
import SwiftUI

struct EventDraft: Identifiable {
    let id = UUID()
    var title = ""
    var start = Date()
    var mailID: String?
}

private struct AgendaEvent: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let calendarName: String
    let color: Color
    var location: String?
    var notes: String?
    var relatedMessage: String?
}

struct CalendarView: View {
    @Environment(MailStore.self) private var mail
    @State private var eventStore = EKEventStore()
    @State private var access = EKEventStore.authorizationStatus(for: .event)
    @State private var date = Calendar.current.startOfDay(for: Date())
    @State private var calendars: [EKCalendar] = []
    @State private var selectedCalendar = ""
    @State private var events: [AgendaEvent] = []
    @State private var selectedEvent: String?
    @State private var requesting = false
    @State private var error: String?
    @State private var demoEvents: [AgendaEvent] = []

    private let calendar = Calendar.current
    private var allowed: Bool { mail.isDemo || access == .fullAccess }
    private var dayEvents: [AgendaEvent] { eventsOn(date) }
    private var canAdd: Bool { mail.isDemo || calendars.contains(where: \.allowsContentModifications) }

    var body: some View {
        @Bindable var mail = mail
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if allowed {
                    dateControls
                    VStack(alignment: .leading, spacing: 5) {
                        Text(calendar.isDateInToday(date) ? "Today" : date.formatted(.dateTime.weekday(.wide)))
                            .font(.system(size: 46, weight: .regular, design: .serif))
                        Text(daySummary).foregroundStyle(WorkspacePaper.secondary)
                    }
                    timeline
                    week
                } else {
                    accessPrompt
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(WorkspacePaper.ink)
        .background(WorkspacePaper.surface)
        .environment(\.colorScheme, .light)
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged, object: eventStore)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onChange(of: date) { _, _ in selectedEvent = nil; refresh() }
        .onChange(of: selectedCalendar) { _, _ in selectedEvent = nil; refresh() }
        .sheet(item: Binding(get: { allowed ? mail.newEvent : nil }, set: { mail.newEvent = $0 })) { draft in
            EventEditor(draft: draft, calendars: calendars.filter(\.allowsContentModifications),
                        defaultCalendar: calendars.first { $0.calendarIdentifier == selectedCalendar && $0.allowsContentModifications }
                            ?? eventStore.defaultCalendarForNewEvents,
                        isDemo: mail.isDemo) { values in
                try save(values, mailID: draft.mailID)
            }
        }
    }

    private var dateControls: some View {
        HStack {
            Text(date, format: .dateTime.month(.wide).day().year())
                .font(.subheadline.weight(.medium))
                .foregroundStyle(WorkspacePaper.secondary)
            Spacer()
            if !calendars.isEmpty {
                Picker("Calendar", selection: $selectedCalendar) {
                    Text("All Calendars").tag("")
                    ForEach(calendars, id: \.calendarIdentifier) { item in
                        Text(item.title).tag(item.calendarIdentifier)
                    }
                }
                .labelsHidden()
            }
            Button { moveDay(-1) } label: { Label("Previous Day", systemImage: "chevron.left") }
                .labelStyle(.iconOnly)
            Button("Today") { date = calendar.startOfDay(for: Date()) }
            Button { moveDay(1) } label: { Label("Next Day", systemImage: "chevron.right") }
                .labelStyle(.iconOnly)
            Button("New Event", systemImage: "plus") {
                let start = calendar.isDateInToday(date) ? Date() : calendar.date(byAdding: .hour, value: 9, to: date) ?? date
                mail.newEvent = EventDraft(start: start)
            }
            .buttonStyle(.borderedProminent)
            .tint(WorkspacePaper.accent)
            .disabled(!canAdd)
        }
    }

    private var accessPrompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Calendar").font(.system(size: 42, design: .serif))
            Text("Show calendars already set up on this Mac, including Fastmail if you’ve added it to Calendar.")
                .foregroundStyle(WorkspacePaper.secondary)
            if access == .denied || access == .restricted {
                Text("Allow Veery Mail in System Settings → Privacy & Security → Calendars.")
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } else {
                Button("Connect Calendar") { Task { await requestAccess() } }
                    .buttonStyle(.borderedProminent)
                    .tint(WorkspacePaper.accent)
                    .disabled(requesting)
            }
            if let error { Text(error).foregroundStyle(WorkspacePaper.accent) }
        }
    }

    private var daySummary: String {
        let count = dayEvents.count
        guard count > 0 else { return "No events scheduled" }
        let text = count == 1 ? "1 event" : "\(count) events"
        guard selectedCalendar.isEmpty, !dayEvents.contains(where: \.allDay),
              let end = dayEvents.map(\.end).max(),
              end < nextDay(after: date) else { return text }
        return "\(text) · Free after \(end.formatted(date: .omitted, time: .shortened))"
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    Text(calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date) ?? date,
                         format: .dateTime.hour())
                    Spacer()
                }
                Text("24h").accessibilityLabel("End of day")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(WorkspacePaper.secondary)
            let timed = dayEvents.filter { !$0.allDay }
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.045))
                    ForEach(Array(timed.enumerated()), id: \.element.id) { index, event in
                        let duration = nextDay(after: date).timeIntervalSince(date)
                        let start = max(0, event.start.timeIntervalSince(date) / duration)
                        let end = min(1, event.end.timeIntervalSince(date) / duration)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(event.color)
                            .frame(width: min(max(2, (end - start) * geometry.size.width),
                                              (1 - start) * geometry.size.width), height: 6)
                            .offset(x: start * geometry.size.width, y: CGFloat(index) * 9 + 4)
                    }
                }
            }
            .frame(height: CGFloat(max(timed.count, 1) * 9 + 5))
            .accessibilityHidden(true)

            ForEach(dayEvents) { event in
                Button {
                    selectedEvent = selectedEvent == event.id ? nil : event.id
                } label: {
                    HStack(spacing: 9) {
                        Circle().fill(event.color).frame(width: 8, height: 8)
                        Text(event.title).fontWeight(.medium)
                        Spacer()
                        Text(event.allDay ? "All Day" : event.start.formatted(date: .omitted, time: .shortened))
                            .foregroundStyle(WorkspacePaper.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if selectedEvent == event.id {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(event.calendarName).font(.caption)
                        if !event.allDay { Text("\(event.start.formatted(date: .omitted, time: .shortened))–\(event.end.formatted(date: .omitted, time: .shortened))") }
                        if let location = event.location, !location.isEmpty { Text(location) }
                        if let notes = event.notes, !notes.isEmpty { Text(notes).textSelection(.enabled) }
                        if let id = event.relatedMessage {
                            Button("Open Related Email") { mail.showLinkedMessage(id) }
                        }
                    }
                    .foregroundStyle(WorkspacePaper.secondary)
                    .padding(.leading, 17)
                }
            }
        }
        .padding(14)
        .background(.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    private var week: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Next 7 Days").font(.system(.title2, design: .serif))
            ForEach(1...7, id: \.self) { offset in
                let day = calendar.date(byAdding: .day, value: offset, to: date) ?? date
                let items = eventsOn(day)
                Divider()
                Button {
                    date = day
                } label: {
                    HStack {
                        Text(day, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                            .frame(width: 114, alignment: .leading)
                        Text(items.first?.title ?? "No events").lineLimit(1)
                        Spacer()
                        if items.count > 1 { Text("+\(items.count - 1)") }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func nextDay(after day: Date) -> Date {
        calendar.date(byAdding: .day, value: 1, to: day) ?? day
    }

    private func eventsOn(_ day: Date) -> [AgendaEvent] {
        let end = nextDay(after: day)
        return events.filter { $0.start < end && ($0.end > day || $0.start >= day) }
    }

    private func moveDay(_ days: Int) {
        if let newDate = calendar.date(byAdding: .day, value: days, to: date) { date = newDate }
    }

    @MainActor private func requestAccess() async {
        requesting = true
        defer { requesting = false; refresh() }
        do { _ = try await eventStore.requestFullAccessToEvents() }
        catch { self.error = error.localizedDescription }
    }

    private func refresh() {
        access = EKEventStore.authorizationStatus(for: .event)
        if mail.isDemo {
            let today = calendar.startOfDay(for: Date())
            let samples: [(Int, Int, String, Color)] = [
                (0, 9, "Creative review", .blue), (0, 12, "Lunch with Jamie", .orange),
                (0, 16, "School pickup", .green), (1, 10, "Production kickoff", .blue),
                (3, 14, "Design handoff", .blue), (6, 12, "Family lunch", .green)
            ]
            events = samples.compactMap { day, hour, title, color in
                guard let start = calendar.date(byAdding: DateComponents(day: day, hour: hour), to: today) else { return nil }
                return AgendaEvent(id: title, title: title, start: start, end: start.addingTimeInterval(1800),
                                   allDay: false, calendarName: "Sample Calendar", color: color)
            } + demoEvents
            events.sort { $0.start < $1.start }
            return
        }
        guard access == .fullAccess else {
            calendars = []
            events = []
            return
        }
        calendars = eventStore.calendars(for: .event).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if !selectedCalendar.isEmpty, !calendars.contains(where: { $0.calendarIdentifier == selectedCalendar }) {
            selectedCalendar = ""
        }
        guard let end = calendar.date(byAdding: .day, value: 8, to: date) else { return }
        let shown = selectedCalendar.isEmpty ? nil : calendars.filter { $0.calendarIdentifier == selectedCalendar }
        let predicate = eventStore.predicateForEvents(withStart: date, end: end, calendars: shown)
        events = eventStore.events(matching: predicate).map { event in
            let identifier = event.calendarItemIdentifier
            let color = event.calendar.cgColor.map { Color(cgColor: $0) } ?? WorkspacePaper.accent
            return AgendaEvent(id: "\(identifier):\(event.startDate.timeIntervalSinceReferenceDate)",
                               title: event.title ?? "Untitled Event", start: event.startDate,
                               end: event.endDate, allDay: event.isAllDay, calendarName: event.calendar.title,
                               color: color, location: event.location, notes: event.notes,
                               relatedMessage: mail.calendarMessage(for: identifier))
        }.sorted { $0.start < $1.start }
    }

    private func save(_ values: EventValues, mailID: String?) throws {
        if mail.isDemo {
            demoEvents.append(AgendaEvent(id: UUID().uuidString, title: values.title, start: values.start,
                                          end: values.end, allDay: values.allDay, calendarName: "Sample Calendar",
                                          color: .blue, location: values.location, notes: values.notes, relatedMessage: mailID))
        } else {
            guard let target = calendars.first(where: { $0.calendarIdentifier == values.calendarID }),
                  target.allowsContentModifications else { throw AgendaError.noWritableCalendar }
            let event = EKEvent(eventStore: eventStore)
            event.title = values.title
            event.isAllDay = values.allDay
            event.startDate = values.start
            event.endDate = values.end
            event.location = values.location
            event.notes = values.notes
            event.calendar = target
            try eventStore.save(event, span: .thisEvent)
            if let mailID { mail.linkCalendarEvent(event.calendarItemIdentifier, to: mailID) }
            if !selectedCalendar.isEmpty { selectedCalendar = target.calendarIdentifier }
        }
        date = calendar.startOfDay(for: values.start)
        refresh()
    }
}

private enum AgendaError: LocalizedError {
    case noWritableCalendar
    var errorDescription: String? { "Choose a calendar that allows changes." }
}

private struct EventValues {
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let calendarID: String
    let location: String
    let notes: String
}

private struct EventEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var start: Date
    @State private var end: Date
    @State private var allDay = false
    @State private var destination: String
    @State private var location = ""
    @State private var notes = ""
    @State private var error: String?
    let calendars: [EKCalendar]
    let isDemo: Bool
    let save: (EventValues) throws -> Void

    init(draft: EventDraft, calendars: [EKCalendar], defaultCalendar: EKCalendar?, isDemo: Bool,
         save: @escaping (EventValues) throws -> Void) {
        _title = State(initialValue: draft.title)
        _start = State(initialValue: draft.start)
        _end = State(initialValue: draft.start.addingTimeInterval(1800))
        _destination = State(initialValue: calendars.first { $0.calendarIdentifier == defaultCalendar?.calendarIdentifier }?.calendarIdentifier
                             ?? calendars.first?.calendarIdentifier ?? "")
        self.calendars = calendars
        self.isDemo = isDemo
        self.save = save
    }

    var body: some View {
        let components: DatePickerComponents = allDay ? [.date] : [.date, .hourAndMinute]
        VStack(alignment: .leading, spacing: 12) {
            Text("New Event").font(.title2)
            Form {
                TextField("Title", text: $title)
                if !isDemo {
                    Picker("Calendar", selection: $destination) {
                        if calendars.isEmpty { Text("No writable calendars").tag("") }
                        ForEach(calendars, id: \.calendarIdentifier) { Text($0.title).tag($0.calendarIdentifier) }
                    }
                }
                Toggle("All day", isOn: $allDay)
                DatePicker("Starts", selection: $start, displayedComponents: components)
                DatePicker("Ends", selection: $end, displayedComponents: components)
                TextField("Location", text: $location)
                TextField("Notes", text: $notes, axis: .vertical)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save Event") { submit() }.keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || (!isDemo && destination.isEmpty))
            }
        }
        .padding(23)
        .frame(width: 430)
        .onChange(of: start) { previous, new in end = end.addingTimeInterval(new.timeIntervalSince(previous)) }
    }

    private func submit() {
        let calendar = Calendar.current
        let begins = allDay ? calendar.startOfDay(for: start) : start
        let finishes = allDay ? (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end) : end
        guard finishes > begins else {
            error = "The end must be after the start."
            return
        }
        do {
            try save(EventValues(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                 start: begins, end: finishes, allDay: allDay,
                                 calendarID: destination, location: location, notes: notes))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
