import SwiftUI
import Charts

struct LibreDailyChart: View {
    let days: [GlucoseDay]
    let interval: DateInterval
    let period: GlucosePeriod
    let unit: GlucoseUnit
    @Binding var selectedTime: Date?

    private var selectedDay: GlucoseDay? {
        guard let selectedTime, selectedTime >= interval.start, selectedTime < interval.end else { return nil }
        // Select the calendar day under the pointer. An empty day must never
        // snap to a neighbouring day's glucose values.
        return days.first { GlucosePeriod.calendar.isDate($0.date, inSameDayAs: selectedTime) }
    }
    private func midpoint(_ day: GlucoseDay) -> Date {
        let end = GlucosePeriod.calendar.date(byAdding: .day, value: 1, to: day.date)!
        return day.date.addingTimeInterval(end.timeIntervalSince(day.date) / 2)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(days) { day in
                    let x = midpoint(day)
                    let selected = day.id == selectedDay?.id
                    if let low = day.summary.minimum, let high = day.summary.maximum {
                        BarMark(x: .value("Day", x), yStart: .value("Low", unit.value(low)), yEnd: .value("High", unit.value(high)), width: .fixed(period == .week ? 12 : 5))
                            .foregroundStyle(LibreTheme.mint.opacity(selected ? 0.75 : 0.25)).cornerRadius(2)
                            .accessibilityLabel(day.date.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                            .accessibilityValue("Low \(unit.format(low)), high \(unit.format(high)) \(unit.label)")
                    }
                    if let average = day.summary.average {
                        PointMark(x: .value("Day", x), y: .value("Average", unit.value(average)))
                            .foregroundStyle(selected ? Color.white : LibreTheme.mint)
                            .symbolSize(selected ? 55 : period == .week ? 32 : 12)
                    }
                }
                if let day = selectedDay {
                    RuleMark(x: .value("Selected day", midpoint(day)))
                        .foregroundStyle(LibreTheme.mint.opacity(0.65)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }.chartXScale(domain: interval.start...interval.end).chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis { AxisMarks(values: .stride(by: .day, count: period == .week ? 1 : 7)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.day()) } }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onTapGesture { location in
                                guard let plot = proxy.plotFrame else { return }
                                let frame = geometry[plot]
                                guard frame.contains(location), let time: Date = proxy.value(atX: location.x - frame.minX) else { return }
                                // An explicit tap persists after mouse-up, unlike
                                // a transient drag/hover selection.
                                selectedTime = time
                            }
                    }
                }.frame(height: 165)
            selectionDetails
            Text("Dot: daily average · bar: daily low–high · \(unit.label)").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
    private var selectionDetails: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let day = selectedDay {
                HStack(alignment: .firstTextBaseline) {
                    Text(day.date.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                        .font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Text(unit.label).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if day.summary.average != nil {
                    HStack {
                        metric("Average", day.summary.average)
                        metric("Low", day.summary.minimum)
                        metric("High", day.summary.maximum)
                    }
                } else {
                    Text("No saved readings for this day").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                Label("Click a bar to see its date, low, and high", systemImage: "cursorarrow.click")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .padding(12).background(LibreTheme.card, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
    }
    private func metric(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value.map { unit.format($0) } ?? "—").font(.system(size: 18, weight: .medium)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
