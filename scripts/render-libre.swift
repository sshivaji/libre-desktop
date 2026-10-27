import AppKit
import SwiftUI

@main struct RenderLibre {
    // Synthetic meal-shaped variation, independent of any account or archive.
    static func glucose(at date: Date, origin: Date) -> Double {
        let calendar = GlucosePeriod.calendar
        let hour = date.timeIntervalSince(calendar.startOfDay(for: date)) / 3600
        let day = date.timeIntervalSince(origin) / 86400
        func peak(_ center: Double, _ width: Double) -> Double {
            exp(-pow((hour - center) / width, 2))
        }
        return 101 + 7 * sin(day / 2.3) + 4 * sin(hour * 1.7)
            + 31 * peak(8.5, 1.2) + 47 * peak(13.2, 1.4) + 37 * peak(19.4, 1.5)
    }

    @MainActor static func render<V: View>(_ view: V, size: NSSize, to file: URL) throws {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        // Capture at the view's native backing resolution; do not upscale.
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No image") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: file)
        window.close()
    }

    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date()
        let origin = GlucosePeriod.calendar.startOfDay(for: now)
        let archive = (0..<(70 * 288)).map { index in
            let date = now.addingTimeInterval(Double(index - 70 * 288) * 300)
            return GlucoseReading(mgdl: glucose(at: date, origin: origin), date: date, trend: nil, unit: .mgdl, high: false, low: false)
        }
        for mode in ["signin", "live", "live-24", "stale", "day", "week", "month", "empty"] {
            let store = LibreStore()
            store.unit = .mgdl
            store.hours = mode == "live-24" ? 24 : 6
            if mode != "signin" {
                let latest = now.addingTimeInterval(mode == "stale" ? -1100 : -60)
                let adjustment = 135 - glucose(at: latest, origin: origin)
                store.history = (0..<288).map { index in
                    let date = latest.addingTimeInterval(Double(index - 287) * 300)
                    let blend = max(0, 1 - latest.timeIntervalSince(date) / 5400)
                    return GlucoseReading(mgdl: glucose(at: date, origin: origin) + adjustment * blend, date: date, trend: 3, unit: .mgdl, high: false, low: false)
                }
                store.reading = store.history.last
                store.needsSignIn = false; store.hasAccount = true; store.online = mode != "stale"
                store.lastFetched = now
                store.connections = [LibreConnection(id: "preview", name: "Preview data", reading: store.reading)]
                store.selectedID = "preview"
                store.message = "DEMO DATA · synthetic readings, no account connected"
                if ["day", "week", "month", "empty"].contains(mode) {
                    store.trends.mode = mode == "empty" ? .day : GlucosePeriod.allCases.first { $0.rawValue.lowercased() == mode }!
                    store.trends.anchor = GlucosePeriod.calendar.date(byAdding: store.trends.mode.component, value: -1, to: now)!
                    store.trends.hasAccount = true; store.trends.person = "Preview data"
                    store.trends.readings = mode == "empty" ? [] : archive
                    store.trends.firstSaved = store.trends.readings.first?.date
                    store.trends.savedCount = store.trends.readings.count
                    store.trends.message = "LibreView history saved · updates every 15 minutes"
                }
            }
            let height: CGFloat = mode == "signin" ? 650 : mode == "week" ? 1050 : 820
            try render(LibreWidget(store: store, pin: {}), size: NSSize(width: 430, height: height), to: folder.appendingPathComponent("\(mode).png"))
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
