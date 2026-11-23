import Foundation

public struct FastmailCalendarCollection: Identifiable, Sendable {
    public let url: URL
    public let title: String
    public let canCreateEvents: Bool
    public let color: String?

    public var id: String { url.absoluteString }
}

public struct FastmailCalendarEvent: Identifiable, Sendable {
    public let id, uid, title: String
    public let start, end: Date
    public let allDay: Bool
    public let location, notes: String?
}

public struct CalendarEventInput: Sendable {
    public let title: String
    public let start, end: Date
    public let allDay: Bool
    public let location, notes: String

    public init(title: String, start: Date, end: Date, allDay: Bool, location: String, notes: String) {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.location = location
        self.notes = notes
    }
}

public enum FastmailCalendarError: LocalizedError {
    case unexpectedResponse, unexpectedURL, invalidDates, readOnly, http(Int)

    public var errorDescription: String? {
        switch self {
        case .unexpectedResponse: return "Fastmail sent an unexpected calendar response."
        case .unexpectedURL: return "Fastmail returned an unexpected calendar address."
        case .invalidDates: return "Choose a valid calendar date range."
        case .readOnly: return "Choose a Fastmail calendar that allows new events."
        case .http(401), .http(403): return "Fastmail didn’t authorize Calendar access."
        case .http(let status): return "Fastmail Calendar returned HTTP \(status)."
        }
    }
}

/// CalDAV runs alongside JMAP. Bearer tokens and redirects stay on Fastmail's CalDAV origin.
public struct FastmailCalendar: Sendable {
    private static let origin = URL(string: "https://caldav.fastmail.com")!
    private static let caldav = "urn:ietf:params:xml:ns:caldav"
    private static let dav = "DAV:"
    private static let colorNamespace = "http://apple.com/ns/ical/"
    private let credentials: OAuthCredentials
    private let transport: HTTPTransport

    public init(credentials: OAuthCredentials, transport: HTTPTransport = NoRedirectTransport()) {
        self.credentials = credentials
        self.transport = transport
    }

    public func calendars() async throws -> [FastmailCalendarCollection] {
        let discovery = Self.origin.appendingPathComponent(".well-known/caldav")
        let principal: URL
        do {
            principal = try await discoverProperty(at: discovery, "current-user-principal", namespace: Self.dav,
                                                   request: "<d:current-user-principal/>", followDiscovery: true)
        } catch FastmailCalendarError.http(let status) where [404, 405].contains(status) {
            principal = try await discoverProperty(at: Self.origin.appendingPathComponent("dav", isDirectory: true),
                                                   "current-user-principal", namespace: Self.dav,
                                                   request: "<d:current-user-principal/>")
        }
        let home = try await discoverProperty(at: principal, "calendar-home-set", namespace: Self.caldav,
                                              request: "<c:calendar-home-set/>")
        let (data, url) = try await request("PROPFIND", url: home, depth: "1", body: Self.propfind("""
            <d:resourcetype/><d:displayname/><d:current-user-privilege-set/>
            <c:supported-calendar-component-set/><a:calendar-color/>
            """))
        return try Self.responses(data).compactMap { response -> FastmailCalendarCollection? in
            let properties = Self.properties(response)
            guard let type = Self.element(properties, "resourcetype", Self.dav),
                  !type.elements(forLocalName: "calendar", uri: Self.caldav).isEmpty,
                  let path = response.elements(forLocalName: "href", uri: Self.dav).first?.stringValue else { return nil }
            if let components = Self.element(properties, "supported-calendar-component-set", Self.caldav),
               !components.elements(forLocalName: "comp", uri: Self.caldav)
                .contains(where: { $0.attribute(forName: "name")?.stringValue == "VEVENT" }) { return nil }
            let privileges = Self.element(properties, "current-user-privilege-set", Self.dav)?
                .elements(forLocalName: "privilege", uri: Self.dav) ?? []
            let writable = privileges.contains { privilege in
                ["all", "write", "bind"].contains { !privilege.elements(forLocalName: $0, uri: Self.dav).isEmpty }
            }
            let target = try Self.checkedURL(path, relativeTo: url)
            return FastmailCalendarCollection(url: target,
                                              title: Self.element(properties, "displayname", Self.dav)?.stringValue ?? "Calendar",
                                              canCreateEvents: writable,
                                              color: Self.element(properties, "calendar-color", Self.colorNamespace)?.stringValue)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public func events(in collection: FastmailCalendarCollection, from start: Date, to end: Date,
                       calendar: Calendar = .current) async throws -> [FastmailCalendarEvent] {
        guard end > start, end.timeIntervalSince(start) <= 91 * 86_400 else { throw FastmailCalendarError.invalidDates }
        var from = start
        var seen = Set<String>()
        var events: [FastmailCalendarEvent] = []
        while from < end {
            try Task.checkCancellation()
            // Bound each server-side recurrence expansion while keeping local day boundaries across DST.
            let boundary = calendar.date(byAdding: .day, value: 30, to: from) ?? from.addingTimeInterval(30 * 86_400)
            let until = min(boundary, end)
            let batch = try await eventBatch(in: collection, from: from, to: until, calendar: calendar)
            events += batch.filter { seen.insert($0.id).inserted }
            from = until
        }
        return events.filter { $0.start < end && ($0.end > start || $0.start >= start) }
            .sorted { $0.start < $1.start }
    }

    private func eventBatch(in collection: FastmailCalendarCollection, from start: Date, to end: Date,
                            calendar: Calendar) async throws -> [FastmailCalendarEvent] {
        let first = CalendarICS.utc(start)
        let last = CalendarICS.utc(end)
        let (data, _) = try await request("REPORT", url: collection.url, depth: "1", body: """
            <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
              <d:prop><c:calendar-data><c:expand start="\(first)" end="\(last)"/></c:calendar-data></d:prop>
              <c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT">
                <c:time-range start="\(first)" end="\(last)"/>
              </c:comp-filter></c:comp-filter></c:filter>
            </c:calendar-query>
            """)
        return try Self.responses(data).flatMap { response -> [FastmailCalendarEvent] in
            guard let ics = Self.element(Self.properties(response), "calendar-data", Self.caldav)?.stringValue else {
                throw FastmailCalendarError.unexpectedResponse
            }
            return CalendarICS.events(ics, calendar: calendar)
        }
    }

    public func create(_ event: CalendarEventInput, in collection: FastmailCalendarCollection,
                       calendar: Calendar = .current) async throws -> String {
        guard collection.canCreateEvents else { throw FastmailCalendarError.readOnly }
        guard event.end > event.start else { throw FastmailCalendarError.invalidDates }
        let uid = UUID().uuidString
        let target = collection.url.appendingPathComponent(uid + ".ics")
        _ = try await request("PUT", url: target, body: CalendarICS.encode(event, uid: uid, calendar: calendar),
                              contentType: "text/calendar; charset=utf-8")
        return uid
    }

    private func discoverProperty(at url: URL, _ name: String, namespace: String,
                                  request property: String, followDiscovery: Bool = false) async throws -> URL {
        let (data, endpoint) = try await request("PROPFIND", url: url, depth: "0", body: Self.propfind(property),
                                                 followDiscovery: followDiscovery)
        for response in try Self.responses(data) {
            let properties = Self.properties(response)
            if let href = Self.element(properties, name, namespace)?
                .elements(forLocalName: "href", uri: Self.dav).first?.stringValue {
                return try Self.checkedURL(href, relativeTo: endpoint)
            }
        }
        throw FastmailCalendarError.unexpectedResponse
    }

    private func request(_ method: String, url: URL, depth: String? = nil, body: String,
                         contentType: String = "application/xml; charset=utf-8",
                         followDiscovery: Bool = false) async throws -> (Data, URL) {
        var endpoint = try Self.checkedURL(url.absoluteString, relativeTo: Self.origin)
        var token = try await credentials.calendarAccessToken()
        var retried = false
        var redirects = 0
        while true {
            try Task.checkCancellation()
            var request = URLRequest(url: endpoint, timeoutInterval: 30)
            request.httpMethod = method
            request.httpBody = Data(body.utf8)
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let depth { request.setValue(depth, forHTTPHeaderField: "Depth") }
            if method == "PUT" { request.setValue("*", forHTTPHeaderField: "If-None-Match") }
            let (data, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw FastmailCalendarError.unexpectedResponse }
            if http.statusCode == 401 && !retried {
                token = try await credentials.calendarAccessToken(rejectedToken: token)
                retried = true
            } else if followDiscovery, [301, 302, 307, 308].contains(http.statusCode), redirects < 3,
                      let location = http.value(forHTTPHeaderField: "Location") {
                endpoint = try Self.checkedURL(location, relativeTo: endpoint)
                redirects += 1
            } else {
                if method == "PUT", [201, 204].contains(http.statusCode) { return (data, endpoint) }
                if method != "PUT", http.statusCode == 207 { return (data, endpoint) }
                throw FastmailCalendarError.http(http.statusCode)
            }
        }
    }

    private static func checkedURL(_ path: String, relativeTo base: URL) throws -> URL {
        guard let url = URL(string: path.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: base)?.absoluteURL,
              url.scheme == "https", url.host == origin.host,
              url.port == nil || url.port == 443, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw FastmailCalendarError.unexpectedURL }
        return url
    }

    private static func propfind(_ properties: String) -> String {
        """
        <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:a="http://apple.com/ns/ical/">
          <d:prop>\(properties)</d:prop>
        </d:propfind>
        """
    }

    private static func responses(_ data: Data) throws -> [XMLElement] {
        let doc = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        guard let root = doc.rootElement(), root.localName == "multistatus", root.uri == dav else {
            throw FastmailCalendarError.unexpectedResponse
        }
        return root.elements(forLocalName: "response", uri: dav)
    }

    private static func properties(_ response: XMLElement) -> [XMLElement] {
        response.elements(forLocalName: "propstat", uri: dav).flatMap { status in
            let line = status.elements(forLocalName: "status", uri: dav).first?.stringValue ?? ""
            guard line.split(whereSeparator: \.isWhitespace).dropFirst().first == "200" else { return [XMLElement]() }
            return status.elements(forLocalName: "prop", uri: dav)
        }
    }

    private static func element(_ properties: [XMLElement], _ name: String, _ namespace: String) -> XMLElement? {
        properties.lazy.compactMap { $0.elements(forLocalName: name, uri: namespace).first }.first
    }
}
