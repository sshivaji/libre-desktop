import Foundation

enum GlucoseLiveHistory {
    static let hours = [3, 6, 12, 24]

    static func archiveInterval(now: Date, calendar: Calendar = GlucosePeriod.calendar) -> DateInterval {
        // Keep all of today for its average, including a 25-hour DST day,
        // as well as yesterday's portion of the rolling 24-hour chart.
        DateInterval(start: min(calendar.startOfDay(for: now), now.addingTimeInterval(-24 * 3600)), end: now)
    }

    static func combine(recent: [GlucoseReading], archived: [GlucoseReading], samePerson: Bool, interval: DateInterval, now: Date) -> [GlucoseReading] {
        let earliest = interval.start.addingTimeInterval(-12 * 60)
        func available(_ readings: [GlucoseReading]) -> [GlucoseReading] {
            GlucoseSummary.unique(readings).filter { $0.date >= earliest && $0.date <= min(now, interval.end) }
        }
        var live = available(recent)
        guard samePerson else { return live }
        let saved = available(archived)
        guard let first = live.first else { return saved }
        // Prefer the live feed throughout its available window. Interleaving
        // the two feeds would double-count overlapping, differently sampled
        // values. Mark the source handoff so no line is invented between them.
        let earlier = saved.filter { $0.date < first.date }
        if !earlier.isEmpty { live[0].breakBefore = true }
        return earlier + live
    }
}

enum GlucosePeriod: String, CaseIterable, Identifiable {
    case live = "Live", day = "Day", week = "Week", month = "Month"
    var id: String { rawValue }
    var component: Calendar.Component { self == .month ? .month : self == .week ? .weekOfYear : .day }
    var isDailyChart: Bool { self == .week || self == .month }
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current; calendar.firstWeekday = 2; calendar.minimumDaysInFirstWeek = 4
        return calendar
    }
    func interval(anchor: Date, now: Date = Date(), hours: Int = 6, calendar: Calendar = Self.calendar) -> DateInterval {
        if self == .live { return DateInterval(start: now.addingTimeInterval(-Double(hours) * 3600), end: now) }
        return calendar.dateInterval(of: component, for: anchor)!
    }
    func title(_ interval: DateInterval) -> String {
        switch self {
        case .live: return "Latest readings"
        case .day: return interval.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case .month: return interval.start.formatted(.dateTime.month(.wide).year())
        case .week: return interval.start.formatted(.dateTime.month(.abbreviated).day()) + " – " + interval.end.addingTimeInterval(-1).formatted(.dateTime.month(.abbreviated).day().year())
        }
    }
}

struct GlucoseSummary {
    let readings: [GlucoseReading]
    let average: Double?
    let minimum: Double?
    let maximum: Double?
    let coveredSeconds: TimeInterval
    let elapsedSeconds: TimeInterval
    var latest: GlucoseReading? { readings.last }
    var coverage: Double { elapsedSeconds > 0 ? min(1, coveredSeconds / elapsedSeconds) : 0 }
    var coverageText: String {
        let minutes = Int(coveredSeconds / 60)
        return "\(minutes / 60)h \(minutes % 60)m recorded · \(Int(coverage * 100))% of elapsed time"
    }
    // Time-weighted trapezoidal average: one-minute live readings must not
    // outweigh five-minute graph readings. Never extend a reading through a
    // gap, beyond the last measurement, or through HI/LO sensor limits.
    static func make(_ input: [GlucoseReading], interval: DateInterval, now: Date = Date()) -> GlucoseSummary {
        let all = unique(input).filter { $0.date <= now }
        let end = min(now, interval.end)
        let visible = all.filter { $0.date >= interval.start && $0.date < interval.end }
        let exact = visible.filter { !$0.high && !$0.low }
        var extrema = exact.map(\.mgdl)
        var area = 0.0, covered = 0.0
        for (left, right) in zip(all, all.dropFirst()) {
            let gap = right.date.timeIntervalSince(left.date)
            guard gap > 0, gap <= 12 * 60, !right.breakBefore, !left.high, !left.low, !right.high, !right.low else { continue }
            let start = max(left.date, interval.start), finish = min(right.date, end)
            guard finish > start else { continue }
            let first = left.mgdl + (right.mgdl - left.mgdl) * start.timeIntervalSince(left.date) / gap
            let last = left.mgdl + (right.mgdl - left.mgdl) * finish.timeIntervalSince(left.date) / gap
            let duration = finish.timeIntervalSince(start)
            extrema.append(contentsOf: [first, last])
            area += (first + last) / 2 * duration; covered += duration
        }
        let fallback = exact.isEmpty ? nil : exact.map(\.mgdl).reduce(0, +) / Double(exact.count)
        return GlucoseSummary(readings: visible, average: covered > 0 ? area / covered : fallback,
                              minimum: extrema.min(), maximum: extrema.max(),
                              coveredSeconds: covered, elapsedSeconds: max(0, end.timeIntervalSince(interval.start)))
    }
    static func unique(_ input: [GlucoseReading]) -> [GlucoseReading] {
        var values = [Date: GlucoseReading]()
        for reading in input { values[reading.date] = reading }
        return values.values.sorted { $0.date < $1.date }
    }
}

struct GlucoseDay: Identifiable {
    let date: Date
    let summary: GlucoseSummary
    var id: Date { date }
    static func make(_ readings: [GlucoseReading], interval: DateInterval, now: Date = Date(), calendar: Calendar = GlucosePeriod.calendar) -> [GlucoseDay] {
        var result = [GlucoseDay](), day = calendar.startOfDay(for: interval.start)
        while day < min(interval.end, now) {
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            let window = DateInterval(start: max(day, interval.start), end: min(next, interval.end))
            result.append(GlucoseDay(date: day, summary: .make(readings, interval: window, now: now)))
            day = next
        }
        return result
    }
}
