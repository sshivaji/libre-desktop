import Foundation

enum GlucoseUnit: String, CaseIterable, Identifiable, Codable {
    case automatic, mgdl, mmol
    var id: String { rawValue }
    var label: String { switch self { case .automatic: return "LibreLinkUp units"; case .mgdl: return "mg/dL"; case .mmol: return "mmol/L" } }
    func resolved(for reading: GlucoseReading?) -> GlucoseUnit { self == .automatic ? (reading?.unit ?? .mgdl) : self }
    func value(_ mgdl: Double) -> Double { self == .mmol ? mgdl / 18.0 : mgdl }
    func format(_ mgdl: Double) -> String { String(format: self == .mmol ? "%.1f" : "%.0f", value(mgdl)) }
}

struct GlucoseReading: Identifiable, Equatable {
    let mgdl: Double
    let date: Date
    let trend: Int?
    let unit: GlucoseUnit
    let high: Bool
    let low: Bool
    var breakBefore: Bool = false
    var id: Date { date }
    var arrow: String { switch trend { case 1: return "↓"; case 2: return "↘"; case 3: return "→"; case 4: return "↗"; case 5: return "↑"; default: return "—" } }
    var trendLabel: String { switch trend { case 1: return "Falling quickly"; case 2: return "Falling"; case 3: return "Steady"; case 4: return "Rising"; case 5: return "Rising quickly"; default: return "Trend unavailable" } }
    func display(in unit: GlucoseUnit) -> String { high ? "HI" : low ? "LO" : unit.resolved(for: self).format(mgdl) }
    func isStale(at now: Date = Date()) -> Bool { now.timeIntervalSince(date) > 5 * 60 || date.timeIntervalSince(now) > 120 }
    func age(at now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes == 0 { return "Less than a minute old" }
        if minutes < 60 { return "\(minutes) min old" }
        return "\(minutes / 60) hr \(minutes % 60) min old"
    }
    static func parse(_ object: [String: Any], now: Date = Date()) -> GlucoseReading? {
        guard let mgdl = number(object["ValueInMgPerDl"]), mgdl > 0, mgdl < 1000,
              let text = object["FactoryTimestamp"] as? String, let date = utcDate(text),
              date.timeIntervalSince1970 > 0, date.timeIntervalSince(now) <= 120 else { return nil }
        // FactoryTimestamp is UTC. Timestamp is the sensor's local wall clock
        // and must never be substituted without a known time zone.
        let unit = number(object["GlucoseUnits"]) == 0 ? GlucoseUnit.mmol : .mgdl
        let high = object["isHigh"] as? Bool ?? false, low = object["isLow"] as? Bool ?? false
        guard !(high && low) else { return nil }
        return GlucoseReading(mgdl: mgdl, date: date, trend: number(object["TrendArrow"]).map(Int.init), unit: unit, high: high, low: low)
    }
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }
    static func utcDate(_ text: String) -> Date? {
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = options
            if let date = formatter.date(from: text) { return date }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        for format in ["M/d/yyyy h:mm:ss a", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

import CoreFoundation

struct LibreConnection: Identifiable, Equatable {
    let id: String
    let name: String
    let reading: GlucoseReading?
    static func choose(_ connections: [LibreConnection], previousID: String?) -> LibreConnection? {
        if let previousID { return connections.first { $0.id == previousID } }
        return connections.count == 1 ? connections.first : nil
    }
    static func parse(_ object: [String: Any], now: Date = Date()) -> LibreConnection? {
        guard let id = object["patientId"] as? String, !id.isEmpty else { return nil }
        let name = [object["firstName"] as? String, object["lastName"] as? String].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let reading = (object["glucoseMeasurement"] as? [String: Any]).flatMap { GlucoseReading.parse($0, now: now) }
        return LibreConnection(id: id, name: name.isEmpty ? "Shared glucose" : String(name.prefix(150)), reading: reading)
    }
}

struct GlucoseSnapshot {
    let connection: LibreConnection
    let history: [GlucoseReading]
    static func parse(_ object: [String: Any], expectedID: String, now: Date = Date()) throws -> GlucoseSnapshot {
        guard let raw = object["connection"] as? [String: Any], let connection = LibreConnection.parse(raw, now: now), connection.id == expectedID else { throw LibreError.invalidResponse }
        let points = (object["graphData"] as? [[String: Any]] ?? []).compactMap { GlucoseReading.parse($0, now: now) }
        return GlucoseSnapshot(connection: connection, history: merge(points, connection.reading.map { [$0] } ?? [], now: now))
    }
    static func merge(_ previous: [GlucoseReading], _ incoming: [GlucoseReading], now: Date = Date()) -> [GlucoseReading] {
        var byTime = [Date: GlucoseReading]()
        for reading in previous + incoming where now.timeIntervalSince(reading.date) <= 12 * 3600 && reading.date.timeIntervalSince(now) <= 120 { byTime[reading.date] = reading }
        return byTime.values.sorted { $0.date < $1.date }
    }
}

struct GlucosePlotPoint: Identifiable {
    let reading: GlucoseReading
    let segment: Int
    var id: Date { reading.date }
    static func make(_ readings: [GlucoseReading]) -> [GlucosePlotPoint] {
        var segment = 0, previous: Date?
        return readings.sorted { $0.date < $1.date }.compactMap { reading in
            // HI/LO values are limits, not exact measurements to plot.
            if reading.high || reading.low { segment += 1; previous = nil; return nil }
            if reading.breakBefore { segment += 1 }
            if let previous, reading.date.timeIntervalSince(previous) > 12 * 60 { segment += 1 }
            previous = reading.date
            return GlucosePlotPoint(reading: reading, segment: segment)
        }
    }
}

enum LibreError: Error, Equatable, LocalizedError {
    case credentials, accountAction, termsRequired, invalidResponse, unsupportedRegion, expired, accessDenied, server, offline, keychain, throttled(Int)
    var errorDescription: String? {
        switch self {
        case .credentials: return "Sign in with your LibreLinkUp email and password—the account that already shows your shared readings."
        case .accountAction: return "Open the official LibreLinkUp app and complete any account or terms prompts, then sign in here again."
        case .termsRequired: return "Abbott requires acceptance of LibreLinkUp’s Terms of Use. Open LibreLinkUp on your iPhone, review the terms, then retry here."
        case .invalidResponse: return "LibreLinkUp returned data this version cannot read. No new reading has been displayed."
        case .unsupportedRegion: return "LibreLinkUp selected an unsupported region. Choose your account’s region and try again."
        case .expired: return "Your LibreLinkUp session expired. Sign in again."
        case .accessDenied: return "LibreLinkUp refused access. Check the account in its official app; this integration may need an update."
        case .server: return "LibreLinkUp is unavailable. Retrying automatically."
        case .offline: return "Unable to reach LibreLinkUp. Check internet access; retrying automatically."
        case .keychain: return "macOS Keychain could not save or retrieve this account. Unlock your login keychain and try again."
        case .throttled: return "LibreLinkUp asked us to wait. Refresh will resume automatically."
        }
    }
    var needsSignIn: Bool { [.credentials, .accountAction, .termsRequired, .expired, .accessDenied, .keychain].contains(self) }
    var code: String {
        switch self {
        case .credentials: return "credentials"
        case .accountAction: return "account_action"
        case .termsRequired: return "terms_required"
        case .invalidResponse: return "invalid_response"
        case .unsupportedRegion: return "unsupported_region"
        case .expired: return "expired"
        case .accessDenied: return "access_denied"
        case .server: return "server"
        case .offline: return "offline"
        case .keychain: return "keychain"
        case .throttled: return "throttled"
        }
    }
}
