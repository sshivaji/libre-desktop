import Foundation
import CryptoKit
import SQLite3

struct LibreArchiveScope: Equatable, Sendable {
    let accountID: String
    let patientID: String
    var key: String {
        // Length delimiters keep account/patient pairs distinct; no identity in filenames.
        let input = "\(accountID.utf8.count):\(accountID)\(patientID.utf8.count):\(patientID)"
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct LibreArchivePage: Sendable {
    let readings: [GlucoseReading]
    let first: Date?
    let last: Date?
    let count: Int
}

enum LibreArchiveError: Error { case unavailable }

actor LibreHistoryArchive {
    private let folder: URL
    init(folder: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Libre Desktop/History")) { self.folder = folder }

    private func database<T>(_ scope: LibreArchiveScope, _ action: (OpaquePointer) throws -> T) throws -> T {
        guard !scope.accountID.isEmpty, !scope.patientID.isEmpty else { throw LibreArchiveError.unavailable }
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let file = folder.appendingPathComponent(scope.key + ".sqlite")
        if !manager.fileExists(atPath: file.path) {
            guard manager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw LibreArchiveError.unavailable }
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        var connection: OpaquePointer?
        guard sqlite3_open_v2(file.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db = connection else {
            if let connection { sqlite3_close(connection) }
            throw LibreArchiveError.unavailable
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        try execute(db, "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA trusted_schema=OFF; CREATE TABLE IF NOT EXISTS readings (time REAL PRIMARY KEY, glucose REAL NOT NULL CHECK(glucose > 0 AND glucose < 1000), trend INTEGER, unit INTEGER NOT NULL, high INTEGER NOT NULL, low INTEGER NOT NULL, breakBefore INTEGER NOT NULL) WITHOUT ROWID;")
        return try action(db)
    }
    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw LibreArchiveError.unavailable }
    }
    private func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw LibreArchiveError.unavailable }
        return statement
    }
    func ingest(_ readings: [GlucoseReading], scope: LibreArchiveScope, now: Date = Date()) throws {
        try database(scope) { db in
            try execute(db, "BEGIN IMMEDIATE")
            do {
                let statement = try prepare(db, "INSERT INTO readings VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(time) DO UPDATE SET glucose=excluded.glucose, trend=excluded.trend, unit=excluded.unit, high=excluded.high, low=excluded.low, breakBefore=excluded.breakBefore")
                defer { sqlite3_finalize(statement) }
                for reading in readings where reading.mgdl.isFinite && reading.mgdl > 0 && reading.mgdl < 1000 && reading.date.timeIntervalSince1970 > 0 && reading.date <= now.addingTimeInterval(120) && !(reading.high && reading.low) {
                    sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                    sqlite3_bind_double(statement, 1, reading.date.timeIntervalSince1970)
                    sqlite3_bind_double(statement, 2, reading.mgdl)
                    if let trend = reading.trend, (1...5).contains(trend) { sqlite3_bind_int(statement, 3, Int32(trend)) }
                    sqlite3_bind_int(statement, 4, reading.unit == .mmol ? 0 : 1)
                    sqlite3_bind_int(statement, 5, reading.high ? 1 : 0)
                    sqlite3_bind_int(statement, 6, reading.low ? 1 : 0)
                    sqlite3_bind_int(statement, 7, reading.breakBefore ? 1 : 0)
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw LibreArchiveError.unavailable }
                }
                try execute(db, "COMMIT")
            } catch {
                try? execute(db, "ROLLBACK")
                throw error
            }
        }
    }
    func read(scope: LibreArchiveScope, interval: DateInterval, now: Date = Date()) throws -> LibreArchivePage {
        try database(scope) { db in
            // Include boundary neighbours for clipped time-weighted averages.
            let statement = try prepare(db, "SELECT time, glucose, trend, unit, high, low, breakBefore FROM readings WHERE time >= ? AND time <= ? ORDER BY time")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, interval.start.addingTimeInterval(-12 * 60).timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, min(now, interval.end.addingTimeInterval(12 * 60)).timeIntervalSince1970)
            var readings = [GlucoseReading]()
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw LibreArchiveError.unavailable }
                let date = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
                let value = sqlite3_column_double(statement, 1)
                guard value.isFinite, value > 0, value < 1000, date.timeIntervalSince1970 > 0 else { throw LibreArchiveError.unavailable }
                let trend = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, 2))
                let high = sqlite3_column_int(statement, 4) != 0, low = sqlite3_column_int(statement, 5) != 0
                guard !(high && low) else { throw LibreArchiveError.unavailable }
                readings.append(GlucoseReading(mgdl: value, date: date, trend: trend, unit: sqlite3_column_int(statement, 3) == 0 ? .mmol : .mgdl, high: high, low: low, breakBefore: sqlite3_column_int(statement, 6) != 0))
            }
            let bounds = try prepare(db, "SELECT MIN(time), MAX(time), COUNT(*) FROM readings WHERE time <= ?")
            defer { sqlite3_finalize(bounds) }
            sqlite3_bind_double(bounds, 1, now.timeIntervalSince1970)
            guard sqlite3_step(bounds) == SQLITE_ROW else { throw LibreArchiveError.unavailable }
            let count = Int(sqlite3_column_int64(bounds, 2))
            return LibreArchivePage(readings: readings,
                                    first: count > 0 ? Date(timeIntervalSince1970: sqlite3_column_double(bounds, 0)) : nil,
                                    last: count > 0 ? Date(timeIntervalSince1970: sqlite3_column_double(bounds, 1)) : nil, count: count)
        }
    }
}
