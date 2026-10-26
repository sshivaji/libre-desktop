import Foundation

struct LibreViewReport {
    // LibreView reports encode recorded device wall time as Unix-shaped
    // numbers. Keep that clock intact on disk; it is not a UTC timestamp.
    let readings: [GlucoseReading]
    let interval: DateInterval
    static func wallDate(_ local: Date, calendar: Calendar = GlucosePeriod.calendar) -> Date {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        return utc.date(from: calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: local))!
    }
    static func displayDate(_ wall: Date, calendar: Calendar = GlucosePeriod.calendar) -> Date? {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: wall)
        guard let date = calendar.date(from: parts), calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date) == parts else { return nil }
        return date
    }
    static func parse(_ html: String, patientID: String, now: Date = Date()) throws -> LibreViewReport {
        // Parse the embedded JSON without evaluating the report's JavaScript.
        guard let marker = html.range(of: #"window\.report(?:Data)?\s*=\s*\{"#, options: .regularExpression) else { throw LibreError.invalidResponse }
        let start = html.index(before: marker.upperBound)
        var depth = 0, quoted = false, escaped = false, end: String.Index?
        for index in html[start...].indices {
            let character = html[index]
            if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else if character == "\"" { quoted = true }
            else if character == "{" { depth += 1 }
            else if character == "}" { depth -= 1; if depth == 0 { end = html.index(after: index); break } }
        }
        guard let end, let root = try JSONSerialization.jsonObject(with: Data(html[start..<end].utf8)) as? [String: Any],
              let data = root["Data"] as? [String: Any], let input = data["Input"] as? [String: Any],
              input["PatientId"] as? String == patientID, let unit = GlucoseReading.number(input["GlucoseUnits"]), [0, 1].contains(unit),
              let days = data["Days"] as? [[String: Any]], let first = GlucoseReading.number(data["StartDate"]),
              let last = GlucoseReading.number(input["EndDate"]), last >= first, last - first <= 100 * 86400,
              data["ReportNotAvailable"] as? Bool != true else { throw LibreError.invalidResponse }
        var readings = [GlucoseReading]()
        let wallNow = wallDate(now)
        for day in days {
            guard let segments = day["Glucose"] as? [[[String: Any]]] else { throw LibreError.invalidResponse }
            for (segmentIndex, segment) in segments.enumerated() {
                for (index, point) in segment.enumerated() {
                    guard let timestamp = GlucoseReading.number(point["Timestamp"]), let value = GlucoseReading.number(point["Value"]) else { continue }
                    let date = Date(timeIntervalSince1970: timestamp), mgdl = unit == 0 ? value * 18 : value
                    guard timestamp >= first, timestamp < last + 86400, date <= wallNow.addingTimeInterval(120), mgdl > 0, mgdl < 1000 else { continue }
                    readings.append(GlucoseReading(mgdl: mgdl, date: date, trend: nil, unit: unit == 0 ? .mmol : .mgdl, high: false, low: false,
                                                   breakBefore: (index == 0 && segmentIndex > 0) || point["IsTimeChange"] as? Bool == true))
                }
            }
        }
        return LibreViewReport(readings: GlucoseSummary.unique(readings), interval: DateInterval(start: Date(timeIntervalSince1970: first), end: Date(timeIntervalSince1970: last + 86400)))
    }
}

final class LibreViewClient {
    typealias Transport = LibreClient.Transport
    private let transport: Transport
    init(transport: Transport? = nil) {
        if let transport { self.transport = transport; return }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 40; config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config, delegate: NoLibreRedirects(), delegateQueue: nil)
        self.transport = { request in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw LibreError.invalidResponse }
            return (data, http)
        }
    }
    static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443, let host = url.host else { return false }
        if LibreClient.regions.values.contains(host) { return true }
        // Reports and their progress channels use Abbott's regional services.
        let regions = ["", "-us", "-eu", "-eu2", "-fr", "-de", "-la", "-ca", "-ap", "-au", "-jp", "-ae"]
        return regions.contains { suffix in ["lrs", "hub"].contains { host == "\($0)\(suffix).libreview.io" } }
    }
    private func send(_ url: URL, account: LibreAccount?, body: [String: Any]? = nil) async throws -> Data {
        guard Self.allowed(url) else { throw LibreError.unsupportedRegion }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("lv", forHTTPHeaderField: "Product")
        request.setValue("3.27.0.42", forHTTPHeaderField: "NEWYU-LV-Web-Version")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let account {
            request.setValue("Bearer " + account.token, forHTTPHeaderField: "Authorization")
            request.setValue(LibreClient.accountHash(account.userID), forHTTPHeaderField: "Account-Id")
        }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await transport(request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw LibreError.offline }
        if response.statusCode == 401 { throw LibreError.expired }
        if response.statusCode == 403 { throw LibreError.accessDenied }
        if response.statusCode == 429 { throw LibreError.throttled(max(60, min(86400, Int(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 900))) }
        if response.statusCode >= 500 { throw LibreError.server }
        guard (200..<300).contains(response.statusCode), data.count <= 30 * 1024 * 1024 else { throw LibreError.invalidResponse }
        return data
    }
    private func json(_ url: URL, account: inout LibreAccount, body: [String: Any]? = nil, login: Bool = false) async throws -> [String: Any] {
        let data = try await send(url, account: login ? nil : account, body: body)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LibreError.invalidResponse }
        let status = (result["status"] as? NSNumber)?.intValue
        let nested = result["data"] as? [String: Any] ?? [:]
        if status == 4 || nested["step"] is [String: Any] { throw LibreError.accountAction }
        if status == 2 { throw LibreError.credentials }
        if status == 429 { throw LibreError.throttled(900) }
        guard status == 0 || result["operation"] is String else { throw LibreError.invalidResponse }
        if let ticket = (nested["authTicket"] ?? result["ticket"]) as? [String: Any], let token = ticket["token"] as? String, let expires = GlucoseReading.number(ticket["expires"]) {
            account.token = token; account.expires = expires
        }
        return result
    }
    func authenticate(_ input: LibreAccount) async throws -> LibreAccount {
        var account = input; account.token = ""; account.userID = ""; account.expires = 0
        var visited = Set<String>()
        for _ in 0..<4 {
            guard LibreClient.regions.values.contains(account.host), visited.insert(account.host).inserted else { throw LibreError.unsupportedRegion }
            let result = try await json(URL(string: "https://\(account.host)/auth/login")!, account: &account, body: ["email": account.email, "password": account.password], login: true)
            guard let data = result["data"] as? [String: Any] else { throw LibreError.invalidResponse }
            if data["redirect"] as? Bool == true {
                var region = (data["region"] as? String ?? "").uppercased()
                if ["GB", "UK"].contains(region) { region = "EU2" }
                guard let host = LibreClient.regions[region] else { throw LibreError.unsupportedRegion }
                account.host = host; continue
            }
            guard let user = data["user"] as? [String: Any], let id = user["id"] as? String, !id.isEmpty, user["accountType"] as? String == "pat" else { throw LibreError.invalidResponse }
            account.userID = id
            account.displayName = [user["firstName"] as? String, user["lastName"] as? String].compactMap { $0 }.joined(separator: " ")
            guard account.isAuthenticated else { throw LibreError.expired }
            return account
        }
        throw LibreError.unsupportedRegion
    }
    func report(_ input: LibreAccount, ending: Date? = nil, days: Int = 90) async throws -> (LibreAccount, LibreViewReport) {
        var account = input
        let response = try await json(URL(string: "https://\(account.host)/reportSettings")!, account: &account)
        guard let settings = response["data"] as? [String: Any], let sources = settings["dataSources"] as? [String: [String: Any]],
              let defaultEnd = GlucoseReading.number(settings["endDate"]) else { throw LibreError.invalidResponse }
        let ordered = sources.values.filter { (($0["daysData"] as? [Int])?.isEmpty == false) }.sorted {
            (GlucoseReading.number($0["uploadDate"]) ?? 0) > (GlucoseReading.number($1["uploadDate"]) ?? 0)
        }
        guard let source = ordered.first, let deviceID = source["id"] as? String, let type = GlucoseReading.number(source["type"]), type >= 1, type < 100000, type.rounded() == type,
              let reportID = Int("5\(Int(type))") else { throw LibreError.invalidResponse }
        let date = ending.map { LibreViewReport.wallDate(GlucosePeriod.calendar.startOfDay(for: $0)).timeIntervalSince1970 } ?? defaultEnd
        let start = date - Double(max(1, min(days, 90)) - 1) * 86400
        let body: [String: Any] = ["PrimaryDeviceId": deviceID, "PrimaryDeviceTypeId": Int(type), "SecondaryDeviceIds": [],
                                  "PrintReportsWithPatientInformation": false, "ReportIds": [reportID], "ClientReportIDs": [5],
                                  "StartDates": [start], "EndDate": date, "PatientId": account.userID,
                                  "CultureCode": "en-US", "GlucoseUnits": 1, "DateFormat": 1, "TimeFormat": 1]
        let generated = try await json(URL(string: "https://\(account.host)/reports")!, account: &account, body: body)
        guard let channelText = (generated["data"] as? [String: Any])?["url"] as? String, let channelURL = URL(string: channelText) else { throw LibreError.invalidResponse }
        let channel = try await json(channelURL, account: &account)
        guard let pollText = (channel["data"] as? [String: Any])?["lp"] as? String, let pollURL = URL(string: pollText) else { throw LibreError.invalidResponse }
        for _ in 0..<8 {
            try Task.checkCancellation()
            let event = try await json(pollURL, account: &account)
            if let operation = event["operation"] as? String, ["error", "failed"].contains(operation) { throw LibreError.server }
            guard let urls = (event["args"] as? [String: Any])?["urls"] as? [String: Any], let link = urls["5"] as? String,
                  let url = URL(string: link) else { continue }
            guard Self.allowed(url), url.host?.hasPrefix("lrs") == true, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw LibreError.unsupportedRegion }
            // LibreView's report renderer authenticates with this query field.
            // Ephemeral networking: URL and embedded report token are never logged or cached.
            components.queryItems = (components.queryItems ?? []).filter { $0.name != "session" } + [URLQueryItem(name: "session", value: account.token)]
            guard let authenticatedURL = components.url else { throw LibreError.invalidResponse }
            let htmlData = try await send(authenticatedURL, account: account)
            guard let html = String(data: htmlData, encoding: .utf8) else { throw LibreError.invalidResponse }
            return (account, try LibreViewReport.parse(html, patientID: account.userID))
        }
        throw LibreError.server
    }
}
