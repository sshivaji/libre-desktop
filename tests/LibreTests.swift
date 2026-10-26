import Foundation

@main struct LibreTests {
    static var checks = 0
    static func check(_ ok: @autoclosure () -> Bool, _ message: String) {
        guard ok() else { fatalError(message) }; checks += 1
    }
    static func raw(_ time: String = "10/25/2026 6:00:00 PM", value: Double = 180, unit: Int = 1) -> [String: Any] {
        ["FactoryTimestamp": time, "Timestamp": "10/25/2026 11:00:00 AM", "ValueInMgPerDl": value, "Value": value,
         "GlucoseUnits": unit, "TrendArrow": 4, "isHigh": false, "isLow": false]
    }
    static func patient(_ id: String, now: Date = Date()) -> [String: Any] {
        var reading = raw(); reading["FactoryTimestamp"] = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        return ["patientId": id, "firstName": "Synthetic", "lastName": id, "glucoseMeasurement": reading]
    }
    static func reply(_ request: URLRequest, _ body: [String: Any], status: Int = 200, headers: [String: String] = [:]) throws -> (Data, HTTPURLResponse) {
        (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
    static func failure(_ expected: LibreError, _ operation: () async throws -> Void) async {
        do { try await operation(); fatalError("Expected \(expected)") }
        catch let error as LibreError { check(error == expected, "Expected \(expected), got \(error)") }
        catch { fatalError("Unexpected error \(error)") }
    }
    static func main() async throws {
        let now = GlucoseReading.utcDate("2026-10-25T18:01:00Z")!
        let reading = GlucoseReading.parse(raw(), now: now)!
        check(reading.date == GlucoseReading.utcDate("2026-10-25T18:00:00Z"), "Factory time is UTC, not Mac wall time")
        check(reading.display(in: .mgdl) == "180" && reading.display(in: .mmol) == "10.0", "Unit conversion")
        check(reading.arrow == "↗" && reading.trendLabel == "Rising", "Known trend mapping")
        check(!reading.isStale(at: now) && reading.isStale(at: now.addingTimeInterval(301)), "Freshness uses measurement time, not successful polling")
        check(reading.age(at: now) == "1 min old", "Reading age")
        var mmol = raw(unit: 0); mmol["Value"] = 10
        check(GlucoseReading.parse(mmol, now: now)!.display(in: .automatic) == "10.0", "API mmol units retained")
        var unknown = raw(); unknown.removeValue(forKey: "TrendArrow")
        check(GlucoseReading.parse(unknown, now: now)!.trendLabel == "Trend unavailable", "Missing trend never becomes steady")
        for bad: Any in [0, -1, 1000, true, "180", NSNull(), Double.nan] {
            var invalid = raw(); invalid["ValueInMgPerDl"] = bad
            check(GlucoseReading.parse(invalid, now: now) == nil, "Invalid numeric data cannot become a glucose reading")
        }
        var localOnly = raw(); localOnly.removeValue(forKey: "FactoryTimestamp")
        check(GlucoseReading.parse(localOnly, now: now) == nil, "No guessing the time zone of local timestamps")
        check(GlucoseReading.parse(raw("10/25/2026 7:00:00 PM"), now: now) == nil, "Reject future readings")
        check(GlucoseReading.parse(raw("bad timestamp"), now: now) == nil, "Reject invalid timestamps")
        var high = raw(); high["isHigh"] = true
        let highReading = GlucoseReading.parse(high, now: now)!
        check(highReading.display(in: .mgdl) == "HI", "Sensor over-range label is not an exact number")
        check(GlucosePlotPoint.make([highReading]).isEmpty, "Sensor limit excluded from numerical plot")
        let previous = GlucoseReading.parse(raw("10/25/2026 5:00:00 PM", value: 100), now: now)!
        let old = GlucoseReading.parse(raw("10/24/2026 5:00:00 PM", value: 90), now: now)!
        check(GlucoseSnapshot.merge([previous, reading, old], [reading], now: now).count == 2, "Bound history, deduplicate measurement timestamps")
        check(GlucosePlotPoint.make([previous, reading]).map(\.segment) == [0, 1], "Do not draw a glucose line through an hour without readings")
        let a = LibreConnection.parse(patient("a", now: now), now: now)!
        let b = LibreConnection.parse(patient("b", now: now), now: now)!
        check(LibreConnection.choose([a], previousID: nil)?.id == "a", "A single shared person can be selected automatically")
        check(LibreConnection.choose([a, b], previousID: nil) == nil, "Multiple people require explicit selection")
        check(LibreConnection.choose([b], previousID: "a") == nil, "Removal of selected person never switches to someone else's glucose")
        check(LibreConnection.choose([a, b], previousID: "b")?.id == "b", "Preserve selected person")
        await failure(.invalidResponse) { _ = try GlucoseSnapshot.parse(["connection": patient("b", now: now)], expectedID: "a", now: now) }

        var calls = 0
        let client = LibreClient { request in
            calls += 1
            check(request.url?.scheme == "https", "TLS only")
            check(request.value(forHTTPHeaderField: "version") == "4.16.0", "Current required protocol header")
            if calls == 1 {
                check(request.url?.host == "api.libreview.io", "Initial routing host")
                check(request.value(forHTTPHeaderField: "Authorization") == nil, "Never send old tokens during login")
                return try reply(request, ["status": 0, "data": ["redirect": true, "region": "la"]])
            }
            if calls == 2 {
                check(request.url?.host == "api-la.libreview.io", "Validated account region redirect")
                return try reply(request, ["status": 0, "data": ["step": NSNull(), "user": ["id": "abc"], "authTicket": ["token": "test-token", "expires": Date().timeIntervalSince1970 + 3600]]])
            }
            check(request.value(forHTTPHeaderField: "Account-Id") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA256 account identifier required by service")
            check(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token", "Authenticated read")
            if calls == 3 { return try reply(request, ["status": 0, "data": [patient("a")]]) }
            return try reply(request, ["status": 0, "data": ["connection": patient("a"), "graphData": []]])
        }
        let input = LibreAccount(email: "test@example.invalid", password: "synthetic-password", host: "api.libreview.io")
        let authenticated = try await client.authenticate(input)
        check(authenticated.isAuthenticated && authenticated.host == "api-la.libreview.io", "Regional auth ticket")
        let connections = try await client.connections(authenticated)
        check(connections.count == 1 && connections[0].id == "a", "Connections parsed")
        let snapshot = try await client.graph(authenticated, id: "a")
        check(snapshot.connection.reading != nil && snapshot.history.count == 1, "Latest measurement included when historical graph is empty")
        await failure(.invalidResponse) { _ = try await client.graph(authenticated, id: "../auth/login") }
        check(calls == 4, "Invalid patient identifier rejected before any network request")

        for (status, code, expected) in [(200, 2, LibreError.credentials), (200, 4, .accountAction), (401, 0, .expired), (403, 0, .accessDenied), (503, 0, .server)] {
            var attempts = 0
            let failing = LibreClient { request in attempts += 1; return try reply(request, ["status": code], status: status) }
            await failure(expected) { _ = try await failing.authenticate(input) }
            check(attempts == 1, "No automatic password retry after auth or account-action failure")
        }
        let throttle = LibreClient { request in try reply(request, ["status": 429], status: 429, headers: ["Retry-After": "600"]) }
        var termsCalls = 0
        let terms = LibreClient { request in
            termsCalls += 1
            check(request.url?.path == "/llu/auth/login", "App does not accept terms without authorization")
            return try reply(request, ["status": 4, "data": ["step": ["type": "tou", "componentName": "AcceptDocument"], "authTicket": ["token": "limited-test-ticket"]]])
        }
        await failure(.termsRequired) { _ = try await terms.authenticate(input) }
        check(termsCalls == 1, "Terms prompt stops retries and limited ticket is not a full session")
        check(LibreError.termsRequired.needsSignIn && LibreError.termsRequired.code == "terms_required", "Terms have a distinct recoverable status")
        let otherAction = LibreClient { request in
            try reply(request, ["status": 0, "data": ["step": ["type": "verifyEmail"], "authTicket": ["token": "limited-test-ticket"]]])
        }
        await failure(.accountAction) { _ = try await otherAction.authenticate(input) }
        await failure(.throttled(600)) { _ = try await throttle.authenticate(input) }
        let unsafe = LibreClient { request in try reply(request, ["status": 0, "data": ["redirect": true, "region": "attacker.example"]]) }
        await failure(.unsupportedRegion) { _ = try await unsafe.authenticate(input) }
        var count = 0
        let looping = LibreClient { request in count += 1; return try reply(request, ["status": 0, "data": ["redirect": true, "region": "EU"]]) }
        await failure(.unsupportedRegion) { _ = try await looping.authenticate(input) }
        check(count == 2, "Region redirect loop is bounded")
        let never = LibreClient { _ in fatalError("Unapproved host must never receive credentials") }
        await failure(.unsupportedRegion) { _ = try await never.authenticate(LibreAccount(email: "a", password: "b", host: "attacker.example")) }
        print("\(checks) Libre model and client checks passed; synthetic responses only, no account or network used.")
    }
}
