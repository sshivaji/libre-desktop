import SwiftUI
import Charts

struct LibreDashboard: View {
    @ObservedObject var store: LibreStore
    @ObservedObject var history: LibreHistoryStore
    @State private var selectedTime: Date?
    @State private var setupOpen = false
    @State private var email = ""
    @State private var password = ""
    private var linked: Bool { history.patientID != nil && history.patientID == store.selectedID }
    private var unit: GlucoseUnit { store.unit.resolved(for: store.reading ?? history.readings.last) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Glucose view", selection: $history.mode) {
                ForEach(GlucosePeriod.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let interval = history.interval(now: context.date)
                let summary = GlucoseSummary.make(history.readings, interval: interval, now: context.date)
                if history.mode == .live {
                    live(summary, now: context.date)
                    recent(now: context.date)
                } else {
                    navigation(interval)
                    period(summary, interval: interval, now: context.date)
                }
            }
            if let warning = history.storageWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
            if history.hasAccount {
                HStack(alignment: .top, spacing: 8) {
                    if history.syncing { ProgressView().controlSize(.small) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(history.message).font(.system(size: 10)).foregroundStyle(history.errorCode == nil ? Color.secondary : .orange)
                        if let date = history.firstSaved {
                            Text("Saved on this Mac since \(date.formatted(date: .abbreviated, time: .omitted))").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Button { history.sync(days: 90) } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(history.syncing || history.needsSignIn).help("Refresh 90 days from LibreView")
                }
            }
            DisclosureGroup(history.hasAccount ? "LibreView connection" : "Connect LibreView history", isExpanded: $setupOpen) {
                VStack(alignment: .leading, spacing: 10) {
                    if history.hasAccount && !history.needsSignIn {
                        Text("\(history.person) · history from LibreView").font(.caption)
                        Text("Readings are saved locally. Sign-out keeps the archive for this account.").font(.caption).foregroundStyle(.secondary)
                        Button("Disconnect LibreView") { history.signOut() }
                    } else {
                        Text("Use your LibreView website account for historical charts. Your existing live connection keeps working.").font(.caption).foregroundStyle(.secondary)
                        TextField("LibreView email", text: $email).textContentType(.username)
                        SecureField("LibreView password", text: $password).textContentType(.password)
                        Button("Connect LibreView") {
                            let secret = password; password = ""
                            history.signIn(email: email, password: secret)
                        }.disabled(email.isEmpty || password.isEmpty || history.syncing)
                        if history.needsSignIn { Text(history.message).font(.caption).foregroundStyle(.orange) }
                    }
                }.padding(.top, 10).textFieldStyle(.roundedBorder)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }.onChange(of: history.mode) { _, _ in selectedTime = nil }
            .onChange(of: history.anchor) { _, _ in selectedTime = nil }
            .onChange(of: store.hours) { _, _ in selectedTime = nil }
    }
    private func live(_ today: GlucoseSummary, now: Date) -> some View {
        let reading = store.reading
        let stale = reading?.isStale(at: now) ?? true
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(store.person).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                Text(reading == nil ? "NO LIVE READING" : stale ? "STALE READING" : !store.online ? "LAST RECEIVED" : "LIVE")
                    .font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(stale || !store.online ? .orange : LibreTheme.mint)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(reading?.display(in: unit) ?? "—").font(.system(size: 68, weight: .light, design: .rounded)).monospacedDigit()
                VStack(alignment: .leading, spacing: 2) {
                    Text(reading?.arrow ?? "—").font(.system(size: 34))
                    Text(unit.label).font(.caption).foregroundStyle(.secondary)
                }
            }.foregroundStyle(stale || !store.online ? Color.white.opacity(0.55) : .white)
            HStack {
                Text(reading?.trendLabel ?? "Waiting for the live feed")
                Spacer()
                Text(reading?.age(at: now) ?? "")
            }.font(.system(size: 11)).foregroundStyle(stale ? .orange : Color.secondary)
            if linked {
                Divider()
                HStack {
                    Text("Today’s average").foregroundStyle(.secondary)
                    Spacer()
                    Text(value(today.average) + " " + unit.label).monospacedDigit()
                }.font(.system(size: 12))
                Text("From LibreView’s available readings today").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }.padding(18).background(LibreTheme.card, in: RoundedRectangle(cornerRadius: 17))
    }
    private func navigation(_ interval: DateInterval) -> some View {
        VStack(spacing: 10) {
            HStack {
                Button { history.move(-1) } label: { Image(systemName: "chevron.left") }.help("Previous \(history.mode.rawValue.lowercased())")
                Text(history.mode.title(interval)).font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity)
                Button { history.move(1) } label: { Image(systemName: "chevron.right") }.disabled(interval.end > Date())
            }.buttonStyle(.borderless)
            HStack {
                DatePicker("Jump to", selection: $history.anchor, in: ...Date(), displayedComponents: .date).datePickerStyle(.field).font(.caption)
                Spacer()
                Button("Today") { history.anchor = Date() }.font(.caption)
            }
        }
    }
    private func period(_ summary: GlucoseSummary, interval: DateInterval, now: Date) -> some View {
        let days = GlucoseDay.make(history.readings, interval: interval, now: now)
        let live = linked && history.mode == .day ? store.reading.flatMap { $0.date >= interval.start && $0.date < interval.end ? $0 : nil } : nil
        let last = live ?? summary.latest
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                Text(history.person).font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(history.mode == .day ? "Daily average" : "Period average").font(.system(size: 11)).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(value(summary.average)).font(.system(size: 42, weight: .light, design: .rounded)).monospacedDigit()
                            Text(unit.label).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if history.mode == .day {
                        VStack(alignment: .trailing, spacing: 5) {
                            Text(live == nil ? "Last recorded" : "Last live value").font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(last?.display(in: unit) ?? "—").font(.system(size: 27, weight: .medium)).monospacedDigit()
                            if let last {
                                Text(last.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary)
                                if live != nil && (last.isStale(at: now) || !store.online) { Text("Stale").font(.system(size: 9)).foregroundStyle(.orange) }
                            }
                        }
                    }
                }
                HStack {
                    stat("Lowest", value(summary.minimum))
                    stat("Highest", value(summary.maximum))
                    stat("Recorded days", "\(days.filter { !$0.summary.readings.isEmpty }.count)/\(days.count)")
                }
            }.padding(17).background(LibreTheme.card, in: RoundedRectangle(cornerRadius: 16))
            if summary.average == nil {
                VStack(spacing: 9) {
                    Image(systemName: "calendar.badge.clock").font(.title2)
                    Text(history.loading || history.syncing ? "Loading saved glucose history…" : "No readings saved for this \(history.mode.rawValue.lowercased())").font(.caption)
                    if history.hasAccount && !history.syncing && !history.loading {
                        Button("Load this period from LibreView") { history.loadSelectedPeriod() }.font(.caption)
                    } else if !history.hasAccount {
                        Button("Connect LibreView") { setupOpen = true }.font(.caption)
                    }
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: 135)
            } else {
                if history.mode.isDailyChart { dailyChart(days, interval: interval) }
                else { lineChart(summary.readings, interval: interval, daily: true) }
                Text(summary.coverageText).font(.system(size: 10)).foregroundStyle(.secondary)
                Text("Average uses recorded time; gaps stay blank. LibreView charts use the sensor’s recorded local dates and times.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                if history.mode.isDailyChart { dailyRows(days) }
            }
        }
    }
    private func recent(now: Date) -> some View {
        let interval = GlucosePeriod.live.interval(anchor: now, now: now, hours: store.hours)
        let readings = store.hours == 24
            ? GlucoseLiveHistory.combine(recent: store.history, archived: history.readings, samePerson: linked, interval: interval, now: now)
            : store.history
        let summary = GlucoseSummary.make(readings, interval: interval, now: now)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent glucose").font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker("Live history", selection: $store.hours) { ForEach(GlucoseLiveHistory.hours, id: \.self) { Text("\($0)h").tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 190)
            }
            lineChart(summary.readings, interval: interval, daily: false)
            HStack { stat("Average", value(summary.average)); stat("Lowest", value(summary.minimum)); stat("Highest", value(summary.maximum)) }
            if store.hours == 24 {
                Text(summary.coverageText).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(linked ? "LibreView history + LibreLinkUp live · gaps stay blank" : "Earlier history needs a matching LibreView connection.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            } else {
                Text("Live feed via LibreLinkUp · refreshes every minute").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
    }
    private func lineChart(_ readings: [GlucoseReading], interval: DateInterval, daily: Bool) -> some View {
        let points = GlucosePlotPoint.make(readings)
        let selected = selectedTime.flatMap { time in points.min { abs($0.reading.date.timeIntervalSince(time)) < abs($1.reading.date.timeIntervalSince(time)) }.flatMap { abs($0.reading.date.timeIntervalSince(time)) <= 6 * 60 ? $0.reading : nil } }
        return VStack(alignment: .leading, spacing: 6) {
            if points.isEmpty {
                Text("No glucose readings in this interval").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: 150)
            } else {
                Chart {
                    ForEach(points) { point in
                        LineMark(x: .value("Time", point.reading.date), y: .value(unit.label, unit.value(point.reading.mgdl)), series: .value("Segment", point.segment))
                            .foregroundStyle(LibreTheme.mint).lineStyle(StrokeStyle(lineWidth: 2))
                        PointMark(x: .value("Time", point.reading.date), y: .value(unit.label, unit.value(point.reading.mgdl)))
                            .foregroundStyle(LibreTheme.mint).symbolSize(points.count < 4 ? 20 : 2)
                    }
                    if let selected { RuleMark(x: .value("Selected time", selected.date)).foregroundStyle(.white.opacity(0.5)) }
                }.chartXScale(domain: interval.start...interval.end, range: .plotDimension(padding: !daily && store.hours == 24 ? 26 : 0))
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartXSelection(value: $selectedTime)
                    .chartXAxis { AxisMarks(values: .stride(by: .hour, count: daily || store.hours == 24 ? 6 : store.hours <= 3 ? 1 : store.hours <= 6 ? 2 : 3)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour())
                    } }
                    .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }.frame(height: 160)
                Text(selected.map { "\($0.date.formatted(date: !daily && store.hours == 24 ? .abbreviated : .omitted, time: .shortened)) · \($0.display(in: unit)) \(unit.label)" } ?? "Select the chart to inspect a reading")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
    private func dailyChart(_ days: [GlucoseDay], interval: DateInterval) -> some View {
        LibreDailyChart(days: days, interval: interval, period: history.mode, unit: unit, selectedTime: $selectedTime)
    }
    private func dailyRows(_ days: [GlucoseDay]) -> some View {
        VStack(spacing: 9) {
            HStack { Text("Day").frame(maxWidth: .infinity, alignment: .leading); Text("Average").frame(width: 65); Text("Low").frame(width: 45); Text("High").frame(width: 45) }
                .font(.system(size: 10)).foregroundStyle(.secondary)
            ForEach(days.reversed()) { day in
                Button {
                    history.anchor = day.date; history.mode = .day
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(day.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                            Text(day.summary.readings.isEmpty ? "No saved readings" : day.summary.coverageText).font(.system(size: 8)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Text(value(day.summary.average)).frame(width: 65)
                        Text(value(day.summary.minimum)).frame(width: 45)
                        Text(value(day.summary.maximum)).frame(width: 45)
                    }.font(.system(size: 11)).monospacedDigit().contentShape(Rectangle())
                }.buttonStyle(.plain)
                Divider().opacity(0.4)
            }
        }.padding(.top, 5)
    }
    private func value(_ value: Double?) -> String { value.map { unit.format($0) } ?? "—" }
    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 16, weight: .medium)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
