import SwiftUI
import Charts

enum LibreTheme {
    static let background = Color(red: 0.055, green: 0.075, blue: 0.09)
    static let mint = Color(red: 0.50, green: 0.91, blue: 0.79)
    static let card = Color.white.opacity(0.045)
}

struct LibreWidget: View {
    @ObservedObject var store: LibreStore
    @ObservedObject var trends: LibreHistoryStore
    let pin: () -> Void
    @State private var pinned = false
    @State private var email = ""
    @State private var password = ""
    @State private var region = "Auto"
    init(store: LibreStore, pin: @escaping () -> Void) {
        self.store = store; self.trends = store.trends; self.pin = pin
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "drop.fill").font(.system(size: 26)).foregroundStyle(LibreTheme.mint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("LIBRE DESKTOP").font(.system(size: 15, weight: .bold)).tracking(2.5)
                        Text("Glucose, at a glance.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { pinned.toggle(); pin() } label: { Image(systemName: pinned ? "pin.fill" : "pin") }
                        .buttonStyle(.plain).help("Keep widget above other windows")
                }
                if store.needsSignIn && !trends.hasAccount {
                    signIn
                } else {
                    if !store.connections.isEmpty && (store.connections.count > 1 || store.selectedID.isEmpty) {
                        Picker("Glucose for", selection: Binding(get: { store.selectedID }, set: { store.select($0) })) {
                            Text("Choose a person").tag("")
                            ForEach(store.connections) { Text($0.name).tag($0.id) }
                        }.disabled(store.busy)
                    }
                    LibreDashboard(store: store, history: trends)
                    HStack {
                        Picker("Units", selection: $store.unit) {
                            ForEach(GlucoseUnit.allCases) { Text($0.label).tag($0) }
                        }.labelsHidden().frame(width: 170)
                        Spacer()
                        Button { store.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(!store.canRefresh)
                    }
                    HStack(alignment: .top, spacing: 8) {
                        if store.busy { ProgressView().controlSize(.small) }
                        else { Circle().fill(store.online ? LibreTheme.mint : Color.orange).frame(width: 7, height: 7).padding(.top, 4) }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(store.message).font(.system(size: 11)).foregroundStyle(.secondary)
                            if let checked = store.lastFetched { Text("Last checked \(checked.formatted(date: .omitted, time: .standard))").font(.system(size: 10)).foregroundStyle(.tertiary) }
                            if !store.online, let retry = store.retryAt { Text("Next attempt \(retry.formatted(date: .omitted, time: .shortened))").font(.system(size: 10)).foregroundStyle(.secondary) }
                        }
                    }
                    HStack { Text("Via LibreLinkUp").foregroundStyle(.tertiary); Spacer(); Button("Sign out") { store.signOut() }.buttonStyle(.borderless) }.font(.system(size: 10))
                }
                Text("For viewing only. Use the Libre app for treatment decisions and alarms.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(24).padding(.top, 12)
        }.frame(minWidth: 410, idealWidth: 430, maxWidth: .infinity, minHeight: 610)
            .background(LibreTheme.background).foregroundStyle(.white).preferredColorScheme(.dark)
    }
    private var signIn: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Connect LibreLinkUp").font(.system(size: 22, weight: .semibold))
                Text("Use the account where you already see your glucose readings.").font(.callout).foregroundStyle(.secondary)
            }.padding(.bottom, 5)
            TextField("LibreLinkUp email", text: $email).textContentType(.username)
            SecureField("Password", text: $password).textContentType(.password).onSubmit { submit() }
            Picker("Account region", selection: $region) {
                Text("Detect automatically").tag("Auto")
                ForEach(LibreClient.regions.keys.sorted().filter { $0 != "Auto" }, id: \.self) { Text($0).tag($0) }
            }
            Button { submit() } label: {
                HStack { Spacer(); if store.busy { ProgressView().controlSize(.small) }; Text(store.busy ? "Connecting…" : "Connect LibreLinkUp"); Spacer() }
            }.buttonStyle(.borderedProminent).tint(LibreTheme.mint).foregroundStyle(.black)
                .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty || store.busy)
            Text(store.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if store.canRetryAccountSetup {
                Button("Retry after account setup") { store.retryAccountSetup() }
                Text("Your credentials are held in memory for this retry. Review any account prompts in the official LibreLinkUp app first.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider().padding(.vertical, 5)
            Label("Credentials saved in macOS Keychain", systemImage: "lock.fill").font(.system(size: 11))
            Text("Connects to Abbott’s LibreLinkUp servers for live readings. Add LibreView for saved daily, weekly, and monthly history. This is an independent viewer.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.textFieldStyle(.roundedBorder).disabled(store.busy)
    }
    private func submit() {
        guard !email.isEmpty, !password.isEmpty, !store.busy else { return }
        let secret = password; password = ""
        store.signIn(email: email, password: secret, region: region)
    }
}
