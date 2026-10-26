import Foundation
import SwiftUI

@MainActor final class LibreHistoryStore: ObservableObject {
    @Published var mode: GlucosePeriod = .live { didSet { reload() } }
    @Published var anchor = Date() { didSet { reload() } }
    @Published var readings: [GlucoseReading] = []
    @Published var firstSaved: Date?
    @Published var lastSaved: Date?
    @Published var savedCount = 0
    @Published var loading = false
    @Published var syncing = false
    @Published var hasAccount = false
    @Published var needsSignIn = false
    @Published var message = "Connect LibreView for daily, weekly, and monthly history."
    @Published var storageWarning: String?
    @Published var lastSync: Date?
    @Published var person = "Your glucose"
    @Published var errorCode: String?
    private(set) var patientID: String?
    var onChange: (() -> Void)?
    private var account: LibreAccount?
    private let client: LibreViewClient
    private let archive: LibreHistoryArchive
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var generation = 0
    private var loadVersion = 0
    private var retryAfter = Date.distantPast
    private var scope: LibreArchiveScope? {
        guard let id = account?.userID, !id.isEmpty else { return nil }
        return LibreArchiveScope(accountID: "libreview-device-clock:" + id, patientID: id)
    }
    init(client: LibreViewClient = LibreViewClient(), archive: LibreHistoryArchive = LibreHistoryArchive()) { self.client = client; self.archive = archive }
    func start(restoreSavedAccount: Bool = true) {
        do {
            account = restoreSavedAccount ? try LibreKeychain.load(history: true) : nil
            if let account {
                hasAccount = true; patientID = account.userID; person = account.displayName ?? "Your glucose"
                reload(); sync(days: 90)
            }
        } catch { message = LibreError.keychain.localizedDescription; errorCode = "keychain" }
    }
    func signIn(email: String, password: String) {
        guard !email.isEmpty, !password.isEmpty, !syncing else { return }
        stop(); readings = []; firstSaved = nil; lastSaved = nil; savedCount = 0; patientID = nil; lastSync = nil
        account = LibreAccount(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password, host: "api.libreview.io")
        hasAccount = true; needsSignIn = false; retryAfter = .distantPast
        sync(days: 90)
    }
    func interval(now: Date = Date()) -> DateInterval {
        // The summary always describes today, independently of the live chart range.
        let period = mode == .live ? GlucosePeriod.day : mode
        return period.interval(anchor: mode == .live ? now : anchor, now: now)
    }
    func move(_ amount: Int) { anchor = GlucosePeriod.calendar.date(byAdding: mode.component, value: amount, to: anchor) ?? anchor }
    func reload() { Task { await load() } }
    private func load() async {
        guard let scope else { return }
        loadVersion += 1; let version = loadVersion, currentGeneration = generation
        let now = Date()
        let interval = mode == .live ? GlucoseLiveHistory.archiveInterval(now: now) : interval(now: now)
        let wallInterval = DateInterval(start: LibreViewReport.wallDate(interval.start), end: LibreViewReport.wallDate(interval.end))
        loading = true
        do {
            let page = try await archive.read(scope: scope, interval: wallInterval, now: LibreViewReport.wallDate(now))
            guard version == loadVersion, currentGeneration == generation else { return }
            readings = page.readings.compactMap { reading in
                guard let date = LibreViewReport.displayDate(reading.date) else { return nil }
                return GlucoseReading(mgdl: reading.mgdl, date: date, trend: reading.trend, unit: reading.unit, high: reading.high, low: reading.low, breakBefore: reading.breakBefore)
            }
            firstSaved = page.first.flatMap { LibreViewReport.displayDate($0) }
            lastSaved = page.last.flatMap { LibreViewReport.displayDate($0) }
            savedCount = page.count; storageWarning = nil
        } catch {
            guard version == loadVersion, currentGeneration == generation else { return }
            storageWarning = "Saved history could not be read. The live connection is still available."
        }
        loading = false; onChange?()
    }
    func loadSelectedPeriod() {
        let range = interval()
        let days = GlucosePeriod.calendar.dateComponents([.day], from: range.start, to: range.end).day ?? 31
        sync(days: max(1, min(90, days)), ending: min(Date(), range.end.addingTimeInterval(-1)))
    }
    func sync(days: Int = 3, ending: Date? = nil) {
        guard let input = account, !syncing, !needsSignIn, retryAfter <= Date() else { return }
        timer?.invalidate(); syncing = true; errorCode = nil
        message = "Downloading LibreView history…"
        let current = generation
        onChange?()
        task = Task { [weak self] in
            guard let self else { return }
            var nextDelay = 15.0 * 60
            do {
                var authenticated = input.isAuthenticated ? input : try await client.authenticate(input)
                let result: (LibreAccount, LibreViewReport)
                do { result = try await client.report(authenticated, ending: ending, days: days) }
                catch LibreError.expired {
                    authenticated = try await client.authenticate(input)
                    result = try await client.report(authenticated, ending: ending, days: days)
                }
                try Task.checkCancellation()
                guard current == generation else { return }
                try LibreKeychain.save(result.0, history: true)
                account = result.0; patientID = result.0.userID; person = result.0.displayName ?? "Your glucose"
                guard let scope else { throw LibreError.invalidResponse }
                do { try await archive.ingest(result.1.readings, scope: scope, now: LibreViewReport.wallDate(Date())) }
                catch { throw LibreArchiveError.unavailable }
                guard current == generation else { return }
                lastSync = Date(); message = "LibreView history saved · updates every 15 minutes"
                await load()
            } catch is CancellationError { return }
            catch {
                guard current == generation else { return }
                if error is LibreArchiveError {
                    storageWarning = "History downloaded but could not be saved on this Mac. Try refreshing after checking disk space."
                    message = "History storage unavailable"; errorCode = "storage"
                } else {
                    let failure = error as? LibreError ?? .invalidResponse
                    errorCode = failure.code; needsSignIn = failure.needsSignIn
                    message = failure == .accountAction ? "Open LibreView to complete its sign-in verification, then reconnect here." : "LibreView: " + failure.localizedDescription
                    if case .throttled(let seconds) = failure { nextDelay = Double(seconds) }
                }
                retryAfter = Date().addingTimeInterval(nextDelay)
            }
            guard current == generation else { return }
            syncing = false; onChange?()
            if !needsSignIn {
                timer = Timer.scheduledTimer(withTimeInterval: nextDelay, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.sync() }
                }
            }
        }
    }
    func signOut() {
        stop(); account = nil; hasAccount = false; patientID = nil; readings = []; savedCount = 0; firstSaved = nil; lastSaved = nil; lastSync = nil
        needsSignIn = false; errorCode = nil; storageWarning = nil
        do { try LibreKeychain.delete(history: true); message = "LibreView disconnected. Saved history stays on this Mac." }
        catch { message = LibreError.keychain.localizedDescription }
        onChange?()
    }
    func stop() { generation += 1; loadVersion += 1; task?.cancel(); timer?.invalidate(); syncing = false; loading = false }
}
