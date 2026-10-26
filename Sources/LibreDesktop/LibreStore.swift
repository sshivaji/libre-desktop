import AppKit
import SwiftUI

@MainActor final class LibreStore: ObservableObject {
    let trends = LibreHistoryStore()
    @Published var reading: GlucoseReading?
    @Published var history: [GlucoseReading] = []
    @Published var connections: [LibreConnection] = []
    @Published var selectedID = ""
    @Published var busy = false
    @Published var needsSignIn = true
    @Published var canRetryAccountSetup = false
    @Published var hasAccount = false
    @Published var online = false
    @Published var message = "Sign in to your existing LibreLinkUp account."
    @Published var lastFetched: Date?
    @Published var retryAt: Date?
    @Published var unit: GlucoseUnit = GlucoseUnit(rawValue: UserDefaults.standard.string(forKey: "GlucoseUnit") ?? "automatic") ?? .automatic {
        didSet { UserDefaults.standard.set(unit.rawValue, forKey: "GlucoseUnit"); onChange?() }
    }
    @Published var hours: Int = {
        let saved = UserDefaults.standard.integer(forKey: "LiveChartHours")
        return GlucoseLiveHistory.hours.contains(saved) ? saved : 6
    }() {
        didSet { UserDefaults.standard.set(hours, forKey: "LiveChartHours") }
    }
    var onChange: (() -> Void)?
    private var account: LibreAccount?
    private let client: LibreClient
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var generation = 0
    private var failures = 0
    private var lastFailure: LibreError?
    private var throttledUntil: Date?
    private var wakeObserver: NSObjectProtocol?
    private let statusFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Libre Desktop")

    init(client: LibreClient = LibreClient()) { self.client = client }
    var displayUnit: GlucoseUnit { unit.resolved(for: reading) }
    var person: String { connections.first { $0.id == selectedID }?.name ?? "Your glucose" }
    var canRefresh: Bool { hasAccount && !busy && !needsSignIn && (throttledUntil ?? .distantPast) <= Date() }

    func start(restoreSavedAccount: Bool = true, restoreSavedHistory: Bool = true) {
        trends.onChange = { [weak self] in self?.report() }
        trends.start(restoreSavedAccount: restoreSavedHistory)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh(); self?.trends.sync(days: 90) }
        }
        do {
            account = restoreSavedAccount ? try LibreKeychain.load() : nil
            hasAccount = account != nil; needsSignIn = account == nil
            if account != nil { refresh() } else { report() }
        } catch { message = LibreError.keychain.localizedDescription; report() }
    }
    func signIn(email: String, password: String, region: String) {
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty, !busy else { return }
        if let until = throttledUntil, until > Date() { message = LibreError.throttled(0).localizedDescription; return }
        stopRequests(); clearReadings()
        account = LibreAccount(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password, host: LibreClient.regions[region] ?? LibreClient.regions["Auto"]!)
        hasAccount = true; needsSignIn = false; failures = 0; canRetryAccountSetup = false; lastFailure = nil
        refresh()
    }
    func retryAccountSetup() {
        guard canRetryAccountSetup, account != nil, !busy else { return }
        needsSignIn = false; canRetryAccountSetup = false
        refresh()
    }
    func select(_ id: String) {
        guard connections.contains(where: { $0.id == id }), var account else { return }
        stopRequests(); clearReadings(keepConnections: true)
        account.selectedID = id; self.account = account; selectedID = id
        do { try LibreKeychain.save(account) } catch { message = LibreError.keychain.localizedDescription }
        refresh()
    }
    func refresh() {
        guard let account, !busy, !needsSignIn else { return }
        if let until = throttledUntil, until > Date() { schedule(until.timeIntervalSinceNow); return }
        timer?.invalidate(); retryAt = nil; busy = true
        message = account.isAuthenticated ? "Refreshing LibreLinkUp…" : "Signing in to LibreLinkUp…"
        let current = generation
        report()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                do { try await self.fetch(account, generation: current) }
                catch LibreError.expired {
                    // A server-invalidated token gets one reauthentication,
                    // never an unbounded password retry loop.
                    var expired = self.account ?? account; expired.expires = 0
                    try await self.fetch(expired, generation: current)
                }
            } catch is CancellationError { return }
            catch {
                guard current == self.generation else { return }
                let failure = error as? LibreError ?? .invalidResponse
                self.lastFailure = failure
                self.online = false; self.message = failure.localizedDescription
                self.needsSignIn = failure.needsSignIn
                self.canRetryAccountSetup = [.termsRequired, .accountAction].contains(failure)
                self.failures += 1
                if case .throttled(let seconds) = failure { self.throttledUntil = Date().addingTimeInterval(Double(seconds)) }
            }
            guard current == self.generation else { return }
            self.busy = false
            if !self.needsSignIn {
                let delay = max(self.throttledUntil?.timeIntervalSinceNow ?? 0, min(900, 60 * pow(2, Double(min(self.failures, 4)))))
                self.schedule(delay)
            }
            self.report()
        }
    }
    private func fetch(_ input: LibreAccount, generation: Int) async throws {
        var authenticated = input
        let renewed = !authenticated.isAuthenticated
        if renewed { authenticated = try await client.authenticate(authenticated) }
        try Task.checkCancellation()
        guard generation == self.generation else { throw CancellationError() }
        if renewed { try LibreKeychain.save(authenticated) }
        account = authenticated
        lastFailure = nil; canRetryAccountSetup = false
        let found = try await client.connections(authenticated)
        try Task.checkCancellation()
        guard generation == self.generation else { throw CancellationError() }
        connections = found
        let choice = LibreConnection.choose(found, previousID: authenticated.selectedID)
        guard let choice else {
            selectedID = ""; reading = nil; history = []; lastFetched = Date(); online = true; failures = 0
            message = found.isEmpty ? "No shared readings found. Confirm that your glucose appears in the LibreLinkUp app." : "Choose whose glucose to display."
            return
        }
        selectedID = choice.id
        if authenticated.selectedID != choice.id {
            authenticated.selectedID = choice.id; try LibreKeychain.save(authenticated); account = authenticated
        }
        let snapshot = try await client.graph(authenticated, id: choice.id)
        try Task.checkCancellation()
        guard generation == self.generation else { throw CancellationError() }
        if let latest = snapshot.connection.reading {
            if reading == nil || latest.date >= reading!.date { reading = latest }
        } else { reading = nil }
        history = GlucoseSnapshot.merge(history, snapshot.history)
        connections = found.map { $0.id == choice.id ? snapshot.connection : $0 }
        lastFetched = Date(); online = true; failures = 0; throttledUntil = nil
        message = reading == nil ? "LibreLinkUp has no valid current reading. Check the sensor in the Libre app." : "Connected to LibreLinkUp · refreshes every minute"
    }
    private func schedule(_ seconds: Double) {
        timer?.invalidate(); retryAt = Date().addingTimeInterval(max(1, seconds))
        timer = Timer.scheduledTimer(withTimeInterval: max(1, seconds), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func signOut() {
        stopRequests(); clearReadings()
        account = nil; hasAccount = false; needsSignIn = true; online = false; canRetryAccountSetup = false; lastFailure = nil
        do { try LibreKeychain.delete(); message = "Signed out. Saved credentials removed from Keychain." }
        catch { message = "Signed out of this session, but the saved Keychain account could not be removed. Unlock your keychain and choose Sign out again." }
        report()
    }
    private func clearReadings(keepConnections: Bool = false) {
        reading = nil; history = []; selectedID = ""; lastFetched = nil; online = false
        if !keepConnections { connections = [] }
    }
    private func stopRequests() { generation += 1; task?.cancel(); timer?.invalidate(); busy = false; retryAt = nil }
    func stop() {
        stopRequests()
        trends.stop()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
    private func report() {
        onChange?()
        // Operational metadata only: no glucose, names, email, token, or password.
        let state: [String: Any] = ["signed_in": account?.isAuthenticated == true && !needsSignIn, "busy": busy, "online": online,
                                  "needs_sign_in": needsSignIn, "reading_available": reading != nil,
                                  "error_code": lastFailure?.code as Any? ?? NSNull(), "account_action_pending": canRetryAccountSetup,
                                  "libreview_signed_in": trends.hasAccount && !trends.needsSignIn, "libreview_syncing": trends.syncing,
                                  "libreview_error": trends.errorCode as Any? ?? NSNull(), "saved_history_points": trends.savedCount,
                                  "loaded_history_points": trends.readings.count,
                                  "loaded_history_span_hours": trends.readings.first.flatMap { first in trends.readings.last.map { $0.date.timeIntervalSince(first.date) / 3600 } } ?? 0,
                                  "live_history_same_person": trends.patientID != nil && trends.patientID == selectedID,
                                  "history_points": history.count, "updated_at": Date().timeIntervalSince1970]
        do {
            try FileManager.default.createDirectory(at: statusFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = statusFolder.appendingPathComponent("status.json")
            try JSONSerialization.data(withJSONObject: state).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { }
    }
}
