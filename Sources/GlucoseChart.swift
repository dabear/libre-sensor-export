//  GlucoseChart.swift — the 8 h history and the last 16 minutes on one time axis, with the
//  70–180 mg/dL range shaded. Readings with quality flags are drawn as triangles.
import SwiftUI
import Charts

struct GlucosePoint: Identifiable {
    let id: String
    let date: Date
    let mgdl: Double
    let isTrend: Bool
    let flagged: Bool
}

/// History older than the trend window, then the trend minutes, oldest first.
func glucosePoints(_ p: ParsedSensor, scannedAt: Date) -> [GlucosePoint] {
    let trendSpan = (p.trend.map(\.minuteOffset).max() ?? 15) + 1
    // slots from before the sensor started hold no reading
    let history = p.history.filter { $0.minuteOffset >= trendSpan && $0.minuteOffset <= p.minutesSinceStart }.compactMap { r in
        r.glucose.map { GlucosePoint(id: "h\(r.minuteOffset)", date: scannedAt.addingTimeInterval(-60 * Double(r.minuteOffset)),
                                     mgdl: $0, isTrend: false, flagged: r.errorBits != 0) }
    }
    let trend = p.trend.compactMap { r in
        r.glucose.map { GlucosePoint(id: "t\(r.minuteOffset)", date: scannedAt.addingTimeInterval(-60 * Double(r.minuteOffset)),
                                     mgdl: $0, isTrend: true, flagged: r.errorBits != 0) }
    }
    return (history + trend).sorted { $0.date < $1.date }
}

struct GlucoseChart: View {
    let points: [GlucosePoint]
    @AppStorage(GlucoseUnit.storageKey) private var unit: GlucoseUnit = .regionDefault

    var body: some View {
        let values = points.map(\.mgdl)
        let lo = min(values.min() ?? 70, 60) - 10, hi = max(values.max() ?? 180, 200) + 10
        Chart {
            if let first = points.first?.date, let last = points.last?.date {
                RectangleMark(xStart: .value("Start", first), xEnd: .value("End", last),
                              yStart: .value("Low", unit.value(70)), yEnd: .value("High", unit.value(180)))
                    .foregroundStyle(Color.green.opacity(0.12))
                    .accessibilityHidden(true)
            }
            ForEach(points) { pt in
                LineMark(x: .value("Time", pt.date), y: .value(unit.label, unit.value(pt.mgdl)))
                    .foregroundStyle(Color.accentColor.opacity(0.55))
                    .interpolationMethod(.monotone)
                    .accessibilityHidden(true)
                PointMark(x: .value("Time", pt.date), y: .value(unit.label, unit.value(pt.mgdl)))
                    .symbol(pt.flagged ? .triangle : .circle)
                    .symbolSize(pt.flagged ? 60 : pt.isTrend ? 14 : 28)
                    .foregroundStyle(pt.flagged ? Color.orange : glucoseColor(pt.mgdl))
                    .accessibilityLabel(pt.date.formatted(date: .omitted, time: .shortened))
                    .accessibilityValue("\(unit.format(pt.mgdl)) \(unit.label)\(pt.flagged ? ", quality flag" : "")")
            }
        }
        .chartYScale(domain: unit.value(lo)...unit.value(hi))
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 2)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            // only lines inside the plotted range (one outside is drawn above the chart)
            AxisMarks(position: .leading, values: [70.0, 180.0, 250.0].filter { (lo...hi).contains($0) }.map(unit.value)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(verbatim: v.formatted(.number.precision(.fractionLength(unit == .mgdl ? 0 : 1)))) }
                }
            }
        }
        .frame(height: 200)
        // VoiceOver: one stop with a summary instead of ~47 points; Audio Graph via the descriptor
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Glucose chart, last 8 hours")
        .accessibilityValue(summary)
        .accessibilityChartDescriptor(GlucoseChartDescriptor(points: points, unit: unit, summary: summary))
    }

    private var summary: String {
        guard let lo = points.map(\.mgdl).min(), let hi = points.map(\.mgdl).max(), let last = points.last else { return "no readings" }
        let flagged = points.filter(\.flagged).count
        return "from \(unit.format(lo)) to \(unit.format(hi)) \(unit.label), newest \(unit.format(last.mgdl))"
            + (flagged > 0 ? ", \(flagged) flagged" : "")
    }
}

/// Audio Graph data for VoiceOver: plain values, so it doesn't depend on the view.
struct GlucoseChartDescriptor: AXChartDescriptorRepresentable {
    let points: [GlucosePoint]; let unit: GlucoseUnit; let summary: String

    func makeChartDescriptor() -> AXChartDescriptor {
        let dates = points.map { $0.date.timeIntervalSince1970 }, values = points.map { unit.value($0.mgdl) }
        let x = AXNumericDataAxisDescriptor(title: "Time", range: (dates.min() ?? 0)...(dates.max() ?? 1), gridlinePositions: []) {
            Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .shortened)
        }
        let decimals = unit == .mgdl ? 0 : 1
        let y = AXNumericDataAxisDescriptor(title: unit.label, range: (values.min() ?? 0)...(values.max() ?? 1), gridlinePositions: []) {
            $0.formatted(.number.precision(.fractionLength(decimals)))
        }
        let series = AXDataSeriesDescriptor(name: "Glucose", isContinuous: true,
                                            dataPoints: points.map { AXDataPoint(x: $0.date.timeIntervalSince1970, y: unit.value($0.mgdl)) })
        return AXChartDescriptor(title: "Glucose, last 8 hours", summary: summary, xAxis: x, yAxis: y,
                                 additionalAxes: [], series: [series])
    }
}
