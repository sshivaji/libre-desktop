import Foundation

@main struct LibreHistoryTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ reason: String) { guard value() else { fatalError(reason) }; checks += 1 }
    static func close(_ a: Double?, _ b: Double, _ reason: String) { check(a != nil && abs(a! - b) < 0.0001, reason) }
    static let day = Date(timeIntervalSince1970: 1785196800)
    static func reading(_ seconds: Double, _ value: Double, high: Bool = false, gap: Bool = false) -> GlucoseReading {
        GlucoseReading(mgdl: value, date: day.addingTimeInterval(seconds), trend: nil, unit: .mgdl, high: high, low: false, breakBefore: gap)
    }
    static func html(patient: String = "abc", unit: Int = 1) throws -> String {
        let body: [String: Any] = ["Data": ["Input": ["PatientId": patient, "GlucoseUnits": unit, "EndDate": day.timeIntervalSince1970, "UserToken": "synthetic } token with \"quote\""],
            "StartDate": day.timeIntervalSince1970, "ReportNotAvailable": false, "Days": [["Date": day.timeIntervalSince1970, "Glucose": [
                [["Timestamp": day.timeIntervalSince1970 + 60, "Value": 10.0, "IsTimeChange": false],
                 ["Timestamp": day.timeIntervalSince1970 + 360, "Value": 12.0, "IsTimeChange": true]],
                [["Timestamp": day.timeIntervalSince1970 + 660, "Value": 15.0, "IsTimeChange": false]]]]]]]
        return "<script>window.reportData = " + String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8)! + "; throw new Error('Must never evaluate scripts');</script>"
    }
    static func reply(_ req: URLRequest, _ body: [String: Any], status: Int = 200) throws -> (Data, HTTPURLResponse) {
        (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    static func failure(_ expected: LibreError, _ operation: () async throws -> Void) async {
        do { try await operation(); fatalError("Expected \(expected)") }
        catch let error as LibreError { check(error == expected, "Unexpected failure: \(error)") }
        catch { fatalError("Unexpected error type") }
    }
    static func main() async throws {
        let now = day.addingTimeInterval(10000), interval = DateInterval(start: day, end: now)
        let mixed = [reading(0, 100), reading(60, 100), reading(120, 100), reading(300, 200)]
        let summary = GlucoseSummary.make(mixed, interval: interval, now: now)
        close(summary.average, 130, "Uneven live/graph sampling is time-weighted")
        check(summary.coveredSeconds == 300 && summary.minimum == 100 && summary.maximum == 200, "Coverage never extrapolates latest measurement")
        let clipped = GlucoseSummary.make(mixed, interval: DateInterval(start: day.addingTimeInterval(60), end: day.addingTimeInterval(300)), now: now)
        close(clipped.average, 137.5, "Weight is clipped at calendar boundaries")
        check(clipped.maximum == 200 && clipped.readings.count == 2, "Range includes clipped edge, but next day reading does not leak into latest")
        let gap = GlucoseSummary.make([reading(0, 100), reading(300, 110), reading(3600, 200)], interval: interval, now: now)
        close(gap.average, 105, "Hour without data does not affect average")
        check(gap.coveredSeconds == 300, "Missing hour has no coverage")
        let limit = GlucoseSummary.make([reading(0, 100), reading(300, 500, high: true), reading(600, 120)], interval: interval, now: now)
        check(limit.coveredSeconds == 0 && limit.maximum == 120, "Sensor HI excluded from numerical range and interpolation")
        let timeChange = GlucoseSummary.make([reading(0, 100), reading(300, 200, gap: true)], interval: interval, now: now)
        check(timeChange.coveredSeconds == 0 && GlucosePlotPoint.make(timeChange.readings).map(\.segment) == [0, 1], "Clock changes split average and chart")
        check(GlucoseSummary.make([], interval: interval, now: now).average == nil, "Missing period stays empty, never zero")
        let one = GlucoseSummary.make([reading(10, 123)], interval: interval, now: now)
        check(one.average == 123 && one.coverage == 0, "Single reading is shown without inventing a duration")
        let tomorrow = GlucoseSummary.make([reading(10001, 123)], interval: interval, now: now)
        check(tomorrow.latest == nil, "Future value cannot become last value")

        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!; calendar.firstWeekday = 2
        let dst = GlucoseReading.utcDate("2026-03-08T18:00:00Z")!
        check(GlucosePeriod.day.interval(anchor: dst, calendar: calendar).duration == 23 * 3600, "Calendar day handles DST")
        let autumn = GlucoseReading.utcDate("2026-11-01T18:00:00Z")!
        check(GlucosePeriod.day.interval(anchor: autumn, calendar: calendar).duration == 25 * 3600, "Autumn day has 25 elapsed hours")
        let month = GlucosePeriod.month.interval(anchor: dst, calendar: calendar)
        check(calendar.component(.day, from: month.start) == 1 && calendar.component(.month, from: month.end) == 4, "Calendar months, not rolling thirty days")
        let week = GlucosePeriod.week.interval(anchor: dst, calendar: calendar)
        check(calendar.component(.weekday, from: week.start) == 2, "Weeks start Monday")
        let wall = LibreViewReport.wallDate(dst, calendar: calendar)
        check(wall != dst && LibreViewReport.displayDate(wall, calendar: calendar) == dst, "Device wall time does not get treated as UTC")
        let nonexistent = GlucoseReading.utcDate("2026-03-08T02:30:00Z")!
        check(LibreViewReport.displayDate(nonexistent, calendar: calendar) == nil, "Do not silently move a nonexistent local clock reading")
        let rollingNow = day.addingTimeInterval(36 * 3600)
        let rolling = GlucosePeriod.live.interval(anchor: rollingNow, now: rollingNow, hours: 24)
        let recent = [reading(26 * 3600, 120), reading(26 * 3600 + 300, 130), reading(36 * 3600 - 60, 140), reading(36 * 3600 + 60, 180)]
        let archived = [reading(12 * 3600 - 300, 100), reading(13 * 3600, 101), reading(25 * 3600 + 300, 110), reading(27 * 3600, 90)]
        let combined = GlucoseLiveHistory.combine(recent: recent, archived: archived, samePerson: true, interval: rolling, now: rollingNow)
        check(combined.contains { $0.date == day.addingTimeInterval(13 * 3600) }, "24-hour view includes yesterday's saved readings")
        check(!combined.contains { $0.date == day.addingTimeInterval(27 * 3600) }, "Overlapping report samples cannot interleave with the live feed")
        check(combined.last?.mgdl == 140 && combined.allSatisfy { $0.date <= rollingNow }, "Live reading stays newest; future values excluded")
        check(combined.first { $0.date == day.addingTimeInterval(26 * 3600) }?.breakBefore == true, "Chart and average do not interpolate across the source handoff")
        let isolated = GlucoseLiveHistory.combine(recent: recent, archived: archived, samePerson: false, interval: rolling, now: rollingNow)
        check(isolated.count == 3 && isolated.first?.mgdl == 120, "A different patient's archive never enters the live chart")
        let cacheOnly = GlucoseLiveHistory.combine(recent: [], archived: archived, samePerson: true, interval: rolling, now: rollingNow)
        check(cacheOnly.count == archived.count, "Matching archive remains useful when recent feed is empty")
        let duplicate = GlucoseLiveHistory.combine(recent: recent + [recent[0]], archived: [], samePerson: true, interval: rolling, now: rollingNow)
        check(duplicate.count == 3, "Duplicate live timestamps counted once")
        let ordinaryWindow = GlucoseLiveHistory.archiveInterval(now: rollingNow, calendar: calendar)
        check(ordinaryWindow.start <= rolling.start && ordinaryWindow.end == rollingNow, "Archive query spans the whole rolling day")
        let longDayNow = GlucoseReading.utcDate("2026-11-02T07:30:00Z")!
        let longWindow = GlucoseLiveHistory.archiveInterval(now: longDayNow, calendar: calendar)
        check(longWindow.start == calendar.startOfDay(for: longDayNow) && longWindow.duration == 24.5 * 3600, "24-hour chart does not truncate today's average on a 25-hour DST day")
        let days = GlucoseDay.make([reading(60, 100), reading(360, 110)], interval: DateInterval(start: day, end: day.addingTimeInterval(86400 * 3)), now: day.addingTimeInterval(86400 * 3))
        check(days.contains { $0.summary.average == nil }, "Empty daily buckets remain present in week/month")

        let parsed = try LibreViewReport.parse(html(unit: 0), patientID: "abc")
        check(parsed.readings.count == 3 && parsed.readings[0].mgdl == 180, "Report JSON extracted and mmol converted without executing scripts")
        check(parsed.readings[1].breakBefore && parsed.readings[2].breakBefore, "Report clock-change and segment flags preserved")
        await failure(.invalidResponse) { _ = try LibreViewReport.parse(html(patient: "other"), patientID: "abc") }
        await failure(.invalidResponse) { _ = try LibreViewReport.parse(html(unit: 3), patientID: "abc") }
        await failure(.invalidResponse) { _ = try LibreViewReport.parse("window.reportData = {", patientID: "abc") }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("libre-history-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let scope = LibreArchiveScope(accountID: "synthetic-account", patientID: "synthetic-patient")
        let archive = LibreHistoryArchive(folder: folder)
        try await archive.ingest(parsed.readings, scope: scope)
        try await archive.ingest(parsed.readings, scope: scope)
        let page = try await LibreHistoryArchive(folder: folder).read(scope: scope, interval: parsed.interval)
        check(page.readings.count == 3 && page.count == 3, "Persistence survives reopening and retries are idempotent")
        check(page.readings[1].breakBefore && page.first == parsed.readings.first?.date, "Archive preserves gaps and timestamps older than 12 hours")
        let other = try await archive.read(scope: LibreArchiveScope(accountID: "different", patientID: "synthetic-patient"), interval: parsed.interval)
        check(other.readings.isEmpty, "Accounts never share cached glucose")
        let another = try await archive.read(scope: LibreArchiveScope(accountID: "synthetic-account", patientID: "other"), interval: parsed.interval)
        check(another.readings.isEmpty, "Patient caches remain separate")
        let file = folder.appendingPathComponent(scope.key + ".sqlite")
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        let folderMode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber
        check(fileMode?.intValue == 0o600, "History file is private")
        check(folderMode?.intValue == 0o700, "History folder is private")
        try await archive.ingest([reading(200, 0), reading(300, .nan), reading(1e10, 120)], scope: scope)
        let unchanged = try await archive.read(scope: scope, interval: parsed.interval)
        check(unchanged.count == 3, "Invalid and future archive samples rejected")

        for url in ["https://attacker.example/r", "https://api.libreview.io.attacker.example/r", "http://api.libreview.io/r", "https://api.libreview.io:444/r", "https://user@api.libreview.io/r"] {
            check(!LibreViewClient.allowed(URL(string: url)!), "Reject unsafe report URL")
        }
        check(LibreViewClient.allowed(URL(string: "https://lrs-us.libreview.io/report/r")!), "Official report renderer allowlisted")
        var requests = 0
        let client = LibreViewClient { req in
            requests += 1
            check(req.value(forHTTPHeaderField: "Product") == "lv", "Uses LibreView protocol")
            switch requests {
            case 1:
                check(req.url?.path == "/auth/login" && req.value(forHTTPHeaderField: "Authorization") == nil, "Website authentication, no stale token")
                return try reply(req, ["status": 0, "data": ["user": ["id": "abc", "accountType": "pat"], "authTicket": ["token": "synthetic-ticket", "expires": Date().timeIntervalSince1970 + 3600]]])
            case 2:
                check(req.value(forHTTPHeaderField: "Account-Id") == LibreClient.accountHash("abc"), "Account hash accompanies history requests")
                return try reply(req, ["status": 0, "data": ["endDate": day.timeIntervalSince1970, "dataSources": ["device": ["id": "device", "type": 40069, "daysData": [1], "uploadDate": day.timeIntervalSince1970]]]])
            case 3:
                let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
                check(body["GlucoseUnits"] as? Int == 1 && body["PrintReportsWithPatientInformation"] as? Bool == false, "Explicit units and no patient info in generated report")
                return try reply(req, ["status": 0, "data": ["url": "https://api-us.libreview.io/channel/test"]])
            case 4: return try reply(req, ["status": 0, "data": ["lp": "https://api-us.libreview.io/poll/test"]])
            case 5: return try reply(req, ["operation": "update", "args": ["urls": ["5": "https://lrs-us.libreview.io/report/test"]]])
            case 6:
                check(URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "session" })?.value == "synthetic-ticket", "Renderer uses the session field required by LibreView")
                return (Data(try html().utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            default: fatalError("Unexpected retry")
            }
        }
        let account = try await client.authenticate(LibreAccount(email: "test@example.invalid", password: "synthetic", host: "api.libreview.io"))
        let (_, report) = try await client.report(account)
        check(requests == 6 && report.readings.count == 3, "Complete website login/report/channel flow")
        let expired = LibreViewClient { req in try reply(req, [:], status: 401) }
        await failure(.expired) { _ = try await expired.report(account) }
        let action = LibreViewClient { req in try reply(req, ["status": 4, "data": ["step": ["type": "2fa"]]]) }
        await failure(.accountAction) { _ = try await action.authenticate(account) }
        print("\(checks) history, calendar, persistence, and LibreView checks passed with synthetic data.")
    }
}
