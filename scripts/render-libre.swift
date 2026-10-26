import AppKit
import SwiftUI

@main struct RenderLibre {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for mode in ["signin", "live", "live-24", "stale", "day", "week", "month", "empty"] {
            let store = LibreStore()
            store.hours = mode == "live-24" ? 24 : 6
            if mode != "signin" {
                let now = Date()
                let latest = now.addingTimeInterval(mode == "stale" ? -1100 : -60)
                store.history = (0..<70).map { index in
                    GlucoseReading(mgdl: 110 + 25 * sin(Double(index) / 9), date: latest.addingTimeInterval(Double(index - 69) * 300), trend: 3, unit: .mgdl, high: false, low: false)
                }
                store.reading = store.history.last
                store.needsSignIn = false; store.hasAccount = true; store.online = mode != "stale"
                store.lastFetched = now
                store.connections = [LibreConnection(id: "preview", name: "Preview data", reading: store.reading)]
                store.selectedID = "preview"
                store.message = "PREVIEW DATA · synthetic readings for layout review"
                if ["day", "week", "month", "empty"].contains(mode) {
                    store.trends.mode = mode == "empty" ? .day : GlucosePeriod.allCases.first { $0.rawValue.lowercased() == mode }!
                    store.trends.hasAccount = true; store.trends.person = "Preview data"
                    var samples = [GlucoseReading]()
                    if mode != "empty" {
                        for index in 0..<9500 where index < 7000 || index > 7300 {
                            let value = 115.0 + 22.0 * sin(Double(index) / 15.0)
                            let date = latest.addingTimeInterval(Double(index - 9499) * 300)
                            samples.append(GlucoseReading(mgdl: value, date: date, trend: nil, unit: .mgdl, high: false, low: false))
                        }
                    }
                    store.trends.readings = samples
                    store.trends.firstSaved = store.trends.readings.first?.date
                    store.trends.savedCount = store.trends.readings.count
                    store.trends.message = "LibreView history saved · updates every 15 minutes"
                }
            }
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 430, height: 730), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: LibreWidget(store: store, pin: {}).frame(width: 430, height: 730))
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No image") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("\(mode).png"))
            window.close()
        }
        print("Rendered eight synthetic previews without displaying windows.")
        for name in ["week-selected", "month-selected", "month-empty"] {
            let period: GlucosePeriod = name == "week-selected" ? .week : .month
            let interval = period.interval(anchor: Date())
            let calendar = GlucosePeriod.calendar
            let count = calendar.dateComponents([.day], from: interval.start, to: interval.end).day!
            let selectedIndex = count / 2
            let selected = calendar.date(byAdding: .day, value: selectedIndex, to: interval.start)!.addingTimeInterval(12 * 3600)
            let samples = (0..<count).flatMap { index -> [GlucoseReading] in
                if name == "month-empty" && index == selectedIndex { return [] }
                let date = calendar.date(byAdding: .day, value: index, to: interval.start)!
                return [GlucoseReading(mgdl: 90 + Double(index), date: date, trend: nil, unit: .mgdl, high: false, low: false),
                        GlucoseReading(mgdl: 150 + Double(index), date: date.addingTimeInterval(300), trend: nil, unit: .mgdl, high: false, low: false)]
            }
            let days = GlucoseDay.make(samples, interval: interval, now: interval.end)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 430, height: 320), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let view = LibreDailyChart(days: days, interval: interval, period: period, unit: .mgdl, selectedTime: .constant(selected))
                .padding(24).frame(width: 430, height: 320).background(LibreTheme.background).foregroundStyle(.white).preferredColorScheme(.dark)
            let host = NSHostingView(rootView: view)
            window.contentView = host; host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("\(name).png"))
            window.close()
        }
        print("Rendered selected week/month and empty-day readouts with synthetic data, without displaying windows or posting input.")
    }
}
