import Foundation
import XCTest
@testable import VeeryMailCore

final class FastmailCalendarTests: XCTestCase {
    private let resource = "https://caldav.fastmail.com/.well-known/caldav"

    private func oauthServer(_ token: @escaping ([String: String], Int) -> [String: Any]) -> MockTransport {
        MockTransport { req, index in
            if req.url!.path.hasSuffix("oauth-authorization-server") {
                return MockTransport.json([
                    "issuer": FastmailOAuth.fastmailIssuer,
                    "authorization_endpoint": FastmailOAuth.fastmailIssuer + "/oauth/authorize",
                    "token_endpoint": FastmailOAuth.fastmailIssuer + "/oauth/token",
                    "registration_endpoint": FastmailOAuth.fastmailIssuer + "/oauth/register",
                    "scopes_supported": ["urn:ietf:params:oauth:scope:mail", FastmailOAuth.calendarScope, "offline_access"],
                    "protected_resources": [FastmailOAuth.jmapResource, self.resource],
                    "code_challenge_methods_supported": ["S256"],
                ])
            }
            return MockTransport.json(token(formBody(req), index))
        }
    }

    func testOneGrantHasTwoResourcesAndSerializesRefreshRotation() async throws {
        let server = oauthServer { form, index in
            XCTAssertEqual(form["refresh_token"], "R\(index - 1)")
            let isCalendar = form["resource"] == self.resource
            if isCalendar { XCTAssertEqual(form["scope"], FastmailOAuth.calendarScope) }
            return ["access_token": isCalendar ? "C" : "M", "token_type": "Bearer", "refresh_token": "R\(index)"]
        }
        let oauth = FastmailOAuth(transport: server)
        let metadata = try await oauth.discover()
        let calendarResource = try FastmailOAuth.calendarResource(for: metadata)
        let scopes = FastmailOAuth.scopes(for: metadata, includeContacts: false) + [FastmailOAuth.calendarScope]
        let registration = OAuthRegistration(issuer: metadata.issuer, clientId: "client",
                                             redirectURI: "http://127.0.0.1/oauth/fastmail", scope: scopes.joined(separator: " "))
        let pending = oauth.beginAuthorization(metadata, registration: registration, port: 49152,
                                               scopes: scopes, calendarResource: calendarResource)
        let query = URLComponents(url: pending.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.filter { $0.name == "resource" }.compactMap(\.value), [FastmailOAuth.jmapResource, resource])
        XCTAssertTrue(query?.first { $0.name == "scope" }?.value?.contains(FastmailOAuth.calendarScope) == true)

        let store = MemoryTokenStore()
        let tokens = OAuthTokens(accessToken: "old", refreshToken: "R0", expiresAt: .distantPast,
                                 scope: scopes.joined(separator: " "), clientId: "client", issuer: metadata.issuer,
                                 calendarResource: resource)
        let credentials = OAuthCredentials(tokens: tokens, metadata: metadata, oauth: oauth, store: store, onSignedOut: { _ in })
        async let mail = credentials.accessToken()
        async let calendar = credentials.calendarAccessToken()
        let pair = try await (mail, calendar)
        XCTAssertEqual(pair.0, "M")
        XCTAssertEqual(pair.1, "C")
        XCTAssertEqual(store.tokens?.accessToken, "M", "Calendar refresh must preserve the JMAP access token")
        XCTAssertEqual(store.tokens?.refreshToken, "R2")
        XCTAssertEqual(store.tokens?.calendarResource, resource)
        let cachedCalendar = try await credentials.calendarAccessToken()
        XCTAssertEqual(cachedCalendar, "C")
        XCTAssertEqual(server.count, 3)
    }

    func testDiscoveryAgendaAndCreationUseFastmailCalDAV() async throws {
        let server = oauthServer { _, _ in ["access_token": "C", "token_type": "bearer", "refresh_token": "R1"] }
        let oauth = FastmailOAuth(transport: server)
        let metadata = try await oauth.discover()
        let creds = OAuthCredentials(tokens: OAuthTokens(accessToken: "M", refreshToken: "R0",
                                                          expiresAt: .distantFuture, scope: "", clientId: "client",
                                                          issuer: metadata.issuer, calendarResource: resource),
                                     metadata: metadata, oauth: oauth, store: MemoryTokenStore(), onSignedOut: { _ in })
        let transport = MockTransport { req, index in
            XCTAssertEqual(req.url?.host, "caldav.fastmail.com")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer C")
            func response(_ path: String, _ props: String) -> String {
                """
                <d:response><d:href>\(path)</d:href><d:propstat><d:prop>\(props)</d:prop>
                <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
                """
            }
            let body: String
            switch index {
            case 0:
                XCTAssertEqual(req.url?.path, "/.well-known/caldav")
                return (301, ["Location": "/dav/"], Data())
            case 1:
                XCTAssertEqual(req.httpMethod, "PROPFIND")
                body = response("/dav/", "<d:current-user-principal><d:href>/dav/principals/user/robin/</d:href></d:current-user-principal>")
            case 2:
                XCTAssertEqual(req.url?.lastPathComponent, "robin")
                body = response("/dav/principals/user/robin/", "<c:calendar-home-set><d:href>/dav/calendars/user/robin/</d:href></c:calendar-home-set>")
            case 3:
                XCTAssertEqual(req.value(forHTTPHeaderField: "Depth"), "1")
                body = response("/dav/calendars/user/robin/work/", """
                    <d:resourcetype><d:collection/><c:calendar/></d:resourcetype><d:displayname>Work</d:displayname>
                    <d:current-user-privilege-set><d:privilege><d:bind/></d:privilege></d:current-user-privilege-set>
                    <c:supported-calendar-component-set><c:comp name="VEVENT"/></c:supported-calendar-component-set>
                    """)
            case 4:
                XCTAssertEqual(req.httpMethod, "REPORT")
                let xml = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
                XCTAssertTrue(xml.contains("<c:expand start=\"20261122T000000Z\""))
                body = response("/dav/calendars/user/robin/work/event.ics", """
                    <c:calendar-data>BEGIN:VCALENDAR
                    BEGIN:VEVENT
                    UID:repeat
                    DTSTART:20261122T090000Z
                    DURATION:PT45M
                    RECURRENCE-ID:20261122T090000Z
                    SUMMARY:Design\\, review
                    BEGIN:VALARM
                    DESCRIPTION:Reminder
                    END:VALARM
                    DESCRIPTION:Line one\\nLine two plus a
                     folded line
                    END:VEVENT
                    END:VCALENDAR</c:calendar-data>
                    """)
            default:
                XCTAssertEqual(req.httpMethod, "PUT")
                XCTAssertEqual(req.value(forHTTPHeaderField: "If-None-Match"), "*")
                let supplied = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
                XCTAssertTrue(supplied.contains("DTSTART;VALUE=DATE:20261122"))
                XCTAssertTrue(supplied.contains("DTEND;VALUE=DATE:20261123"))
                XCTAssertTrue(supplied.contains("LOCATION:Home\\, office"))
                return (201, [:], Data())
            }
            return (207, [:], Data("""
                <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">\(body)</d:multistatus>
                """.utf8))
        }
        let service = FastmailCalendar(credentials: creds, transport: transport)
        let calendars = try await service.calendars()
        let work = try XCTUnwrap(calendars.first)
        XCTAssertEqual(work.title, "Work")
        XCTAssertTrue(work.canCreateEvents)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 22)))
        let end = start.addingTimeInterval(86_400)
        let events = try await service.events(in: work, from: start, to: end, calendar: calendar)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.title, "Design, review")
        XCTAssertEqual(event.notes, "Line one\nLine two plus afolded line")
        XCTAssertEqual(event.end.timeIntervalSince(event.start), 45 * 60)
        let uid = try await service.create(CalendarEventInput(title: "Holiday", start: start, end: end,
                                                             allDay: true, location: "Home, office", notes: ""), in: work,
                                           calendar: calendar)
        XCTAssertEqual(transport.requests.last?.url?.lastPathComponent, "\(uid).ics")
        XCTAssertEqual(server.count, 2, "All CalDAV requests reused the same calendar access token")
    }

    func testDiscoveryDoesNotSendBearerToAnotherHost() async throws {
        let server = oauthServer { _, _ in ["access_token": "C", "token_type": "bearer", "refresh_token": "R1"] }
        let oauth = FastmailOAuth(transport: server)
        let metadata = try await oauth.discover()
        let creds = OAuthCredentials(tokens: OAuthTokens(accessToken: "M", refreshToken: "R0",
                                                          expiresAt: .distantFuture, scope: "", clientId: "client",
                                                          issuer: metadata.issuer, calendarResource: resource),
                                     metadata: metadata, oauth: oauth, store: MemoryTokenStore(), onSignedOut: { _ in })
        let transport = MockTransport { _, _ in (302, ["Location": "https://wrong.example/calendar"], Data()) }
        do {
            _ = try await FastmailCalendar(credentials: creds, transport: transport).calendars()
            XCTFail("Discovery accepted another host")
        } catch FastmailCalendarError.unexpectedURL {
            XCTAssertEqual(transport.count, 1)
        }
    }
}
