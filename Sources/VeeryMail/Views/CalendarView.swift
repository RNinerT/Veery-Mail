import AppKit
import VeeryMailCore
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
    @State private var authorization = FastmailSignIn()
    @AppStorage("contacts.enabled") private var includeContacts = true
    @State private var date = Calendar.current.startOfDay(for: Date())
    @State private var calendars: [FastmailCalendarCollection] = []
    @State private var selectedCalendar = ""
    @State private var events: [AgendaEvent] = []
    @State private var selectedEvent: String?
    @State private var loading = false
    @State private var refreshCount = 0
    @State private var error: String?
    @State private var needsAuthorization = false
    @State private var demoEvents: [AgendaEvent] = []

    private let calendar = Calendar.current
    private var allowed: Bool { mail.isDemo || mail.fastmailCalendar != nil }
    private var dayEvents: [AgendaEvent] { eventsOn(date) }
    private var canAdd: Bool { mail.isDemo || calendars.contains(where: \.canCreateEvents) }

    private struct AgendaQuery: Equatable {
        let date: Date
        let calendarID: String
        let generation: Int
        let hasCalendar: Bool
        let refresh: Int
    }

    private var query: AgendaQuery {
        AgendaQuery(date: date, calendarID: selectedCalendar, generation: mail.generation,
                    hasCalendar: allowed, refresh: refreshCount)
    }

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
                    if needsAuthorization {
                        accessPrompt
                        if let error, !authorization.isBusy { Text(error).foregroundStyle(WorkspacePaper.accent) }
                    } else if let error {
                        Text(error).foregroundStyle(WorkspacePaper.accent)
                    } else if loading {
                        ProgressView("Loading Fastmail Calendar…").controlSize(.small)
                    } else {
                        timeline
                        week
                    }
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
        .task(id: query) { await refresh(query) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if allowed && !authorization.isBusy { refreshCount += 1 }
        }
        .onChange(of: authorization.stage) { previous, stage in
            if previous == .finishing && stage == .idle && allowed { refreshCount += 1 }
        }
        .onDisappear { authorization.cancel() }
        .sheet(item: Binding(get: { canAdd ? mail.newEvent : nil }, set: { mail.newEvent = $0 })) { draft in
            EventEditor(draft: draft, calendars: calendars.filter(\.canCreateEvents),
                        defaultCalendar: calendars.first { $0.id == selectedCalendar && $0.canCreateEvents },
                        isDemo: mail.isDemo) { values in
                try await save(values, mailID: draft.mailID)
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
                    ForEach(calendars, id: \.id) { item in
                        Text(item.title).tag(item.id)
                    }
                }
                .labelsHidden()
            }
            Button { moveDay(-1) } label: { Label("Previous Day", systemImage: "chevron.left") }
                .labelStyle(.iconOnly)
            Button { refreshCount += 1 } label: { Label("Refresh Calendar", systemImage: "arrow.clockwise") }
                .labelStyle(.iconOnly)
                .help("Refresh Calendar")
                .disabled(loading)
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
            Text("Use the Fastmail account already open in Veery. Fastmail may ask you to approve Calendar access once.")
                .foregroundStyle(WorkspacePaper.secondary)
            Button("Allow Fastmail Calendar Access") {
                authorization.start(store: mail, includeContacts: includeContacts || mail.client?.contactsAccountId != nil,
                                    authorizeCalendar: true)
            }
            .buttonStyle(.borderedProminent)
            .tint(WorkspacePaper.accent)
            .disabled(authorization.isBusy || mail.phase != .ready)
            switch authorization.stage {
            case .preparing, .finishing:
                ProgressView("Verifying Fastmail Calendar access…").controlSize(.small)
            case .waitingForBrowser:
                HStack {
                    Text("Approve access in your browser, then return here.")
                    Button("Cancel") { authorization.cancel() }
                }
            case .failed(let message):
                Text(message).foregroundStyle(WorkspacePaper.accent)
            case .idle: EmptyView()
            }
        }
    }

    private var daySummary: String {
        if loading || error != nil { return "Fastmail Calendar" }
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

    private func refresh(_ request: AgendaQuery) async {
        selectedEvent = nil
        error = nil
        needsAuthorization = false
        loading = allowed
        defer { if !Task.isCancelled, request == query { loading = false } }
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
        guard let service = mail.fastmailCalendar else {
            calendars = []
            events = []
            return
        }
        guard let end = calendar.date(byAdding: .day, value: 8, to: request.date) else { return }
        do {
            let available = try await service.calendars()
            guard !Task.isCancelled, request == query else { return }
            calendars = available
            if !request.calendarID.isEmpty, !available.contains(where: { $0.id == request.calendarID }) {
                selectedCalendar = ""
                return
            }
            let shown = request.calendarID.isEmpty ? available : available.filter { $0.id == request.calendarID }
            var agenda: [AgendaEvent] = []
            for collection in shown {
                let instances = try await service.events(in: collection, from: request.date, to: end, calendar: calendar)
                guard !Task.isCancelled, request == query else { return }
                let color = collection.color.flatMap(calendarColor) ?? WorkspacePaper.accent
                agenda += instances.map { event in
                    AgendaEvent(id: collection.id + ":" + event.id, title: event.title, start: event.start,
                                end: event.end, allDay: event.allDay, calendarName: collection.title,
                                color: color, location: event.location, notes: event.notes,
                                relatedMessage: mail.calendarMessage(for: event.uid))
                }
            }
            events = agenda.sorted { $0.start < $1.start }
        } catch {
            guard !Task.isCancelled, request == query else { return }
            events = []
            if case FastmailCalendarError.http(let status) = error { needsAuthorization = [401, 403].contains(status) }
            if case OAuthError.server(let code, _) = error {
                needsAuthorization = ["invalid_target", "invalid_scope", "insufficient_scope"].contains(code)
            }
            self.error = error.localizedDescription
        }
    }

    private func calendarColor(_ value: String) -> Color? {
        let hex = value.dropFirst()
        guard value.first == "#", [6, 8].contains(hex.count), let rgb = UInt32(hex.prefix(6), radix: 16) else { return nil }
        return Color(red: Double((rgb >> 16) & 255) / 255,
                     green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }

    private func save(_ values: EventValues, mailID: String?) async throws {
        let generation = mail.generation
        if mail.isDemo {
            demoEvents.append(AgendaEvent(id: UUID().uuidString, title: values.title, start: values.start,
                                          end: values.end, allDay: values.allDay, calendarName: "Sample Calendar",
                                          color: .blue, location: values.location, notes: values.notes, relatedMessage: mailID))
        } else {
            guard let service = mail.fastmailCalendar else { throw JMAPError.notConnected }
            guard let target = calendars.first(where: { $0.id == values.calendarID }) else {
                throw FastmailCalendarError.readOnly
            }
            let event = CalendarEventInput(title: values.title, start: values.start, end: values.end,
                                           allDay: values.allDay, location: values.location, notes: values.notes)
            let uid = try await service.create(event, in: target, calendar: calendar)
            guard mail.isLive(generation) else { return }
            if let mailID { mail.linkCalendarEvent(uid, to: mailID) }
            if !selectedCalendar.isEmpty { selectedCalendar = target.id }
        }
        date = calendar.startOfDay(for: values.start)
        refreshCount += 1
    }
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
    @State private var saving = false
    let calendars: [FastmailCalendarCollection]
    let isDemo: Bool
    let save: (EventValues) async throws -> Void

    init(draft: EventDraft, calendars: [FastmailCalendarCollection], defaultCalendar: FastmailCalendarCollection?, isDemo: Bool,
         save: @escaping (EventValues) async throws -> Void) {
        _title = State(initialValue: draft.title)
        _start = State(initialValue: draft.start)
        _end = State(initialValue: draft.start.addingTimeInterval(1800))
        _destination = State(initialValue: calendars.first { $0.id == defaultCalendar?.id }?.id
                             ?? calendars.first?.id ?? "")
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
                        ForEach(calendars, id: \.id) { Text($0.title).tag($0.id) }
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
                if saving { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }.disabled(saving)
                Button("Save Event") { Task { await submit() } }.keyboardShortcut(.defaultAction)
                    .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || (!isDemo && destination.isEmpty))
            }
        }
        .padding(23)
        .frame(width: 430)
        .interactiveDismissDisabled(saving)
        .onChange(of: start) { previous, new in end = end.addingTimeInterval(new.timeIntervalSince(previous)) }
    }

    private func submit() async {
        guard !saving else { return }
        let calendar = Calendar.current
        let begins = allDay ? calendar.startOfDay(for: start) : start
        let finishes = allDay ? (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end) : end
        guard finishes > begins else {
            error = "The end must be after the start."
            return
        }
        saving = true
        defer { saving = false }
        do {
            try await save(EventValues(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                 start: begins, end: finishes, allDay: allDay,
                                 calendarID: destination, location: location, notes: notes))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
