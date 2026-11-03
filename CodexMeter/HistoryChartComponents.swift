import AppKit
import Charts
import SwiftUI

enum HistoryPalette {
    static let accent = Color(red: 0.22, green: 0.72, blue: 0.79)
    static let accentBright = Color(red: 0.33, green: 0.82, blue: 0.88)
    static let warning = Color.orange
}

struct QuotaHistoryChart: View {
    private struct IdealPoint: Identifiable {
        let id: String
        let date: Date
        let remainingPercent: Double
        let cycleID: String
    }

    let series: QuotaHistorySeries
    var showsAxes = true

    var body: some View {
        Chart {
            ForEach(series.gaps) { gap in
                RectangleMark(
                    xStart: .value(L10n.string("history.gap.start"), gap.start),
                    xEnd: .value(L10n.string("history.gap.end"), gap.end),
                    yStart: .value(L10n.string("history.chart.minimum"), 0),
                    yEnd: .value(L10n.string("history.chart.maximum"), 100)
                )
                .foregroundStyle(.secondary.opacity(0.10))
            }

            ForEach(idealPoints) { point in
                LineMark(
                    x: .value(L10n.string("history.chart.time"), point.date),
                    y: .value(L10n.string("history.legend.ideal"), point.remainingPercent),
                    series: .value(
                        L10n.string("history.chart.reset"),
                        "ideal-\(point.cycleID)"
                    )
                )
                .foregroundStyle(.secondary.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: showsAxes ? 1.25 : 1, dash: [5, 5]))
            }

            ForEach(series.points) { point in
                AreaMark(
                    x: .value(L10n.string("history.chart.time"), point.date),
                    y: .value(L10n.string("quota.remaining"), point.remainingPercent),
                    series: .value(
                        L10n.string("history.chart.reset"),
                        "actual-area-\(point.cycleID)"
                    )
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(
                        colors: [HistoryPalette.accent.opacity(showsAxes ? 0.28 : 0.22), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }

            ForEach(smoothedPoints) { point in
                LineMark(
                    x: .value(L10n.string("history.chart.time"), point.date),
                    y: .value(L10n.string("quota.remaining"), point.remainingPercent),
                    series: .value(
                        L10n.string("history.chart.reset"),
                        "actual-line-\(point.cycleID)"
                    )
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(HistoryPalette.accentBright.opacity(0.55))
                .lineStyle(StrokeStyle(
                    lineWidth: showsAxes ? 1.25 : 1,
                    lineCap: .round,
                    lineJoin: .round,
                    dash: showsAxes ? [2, 4] : [1, 3]
                ))
            }

            if let latest = series.points.last {
                PointMark(
                    x: .value(L10n.string("history.chart.time"), latest.date),
                    y: .value(L10n.string("quota.remaining"), latest.remainingPercent)
                )
                .foregroundStyle(HistoryPalette.accentBright)
                .symbolSize(showsAxes ? 38 : 24)
            }
        }
        .chartXScale(domain: series.start...series.end)
        .chartYScale(domain: 0...100)
        .chartXAxis {
            if showsAxes {
                if series.range == .currentCycle {
                    AxisMarks(values: .stride(by: usesHourlyAxis ? .hour : .day)) { value in
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(axisLabel(for: date, usesWeekday: true))
                            }
                        }
                    }
                } else {
                    AxisMarks(values: .automatic(desiredCount: 7)) { value in
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(axisLabel(for: date, usesWeekday: false))
                            }
                        }
                    }
                }
            }
        }
        .chartYAxis {
            if showsAxes {
                AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.16))
                    AxisValueLabel {
                        if let percent = value.as(Double.self) {
                            Text("\(Int(percent.rounded()))%")
                        }
                    }
                }
            }
        }
        .accessibilityLabel(L10n.string("history.quota.title"))
    }

    private var idealPoints: [IdealPoint] {
        series.idealSegments.flatMap { segment in
            [
                IdealPoint(
                    id: "\(segment.id)-start",
                    date: segment.start,
                    remainingPercent: segment.startPercent,
                    cycleID: segment.id
                ),
                IdealPoint(
                    id: "\(segment.id)-end",
                    date: segment.end,
                    remainingPercent: segment.endPercent,
                    cycleID: segment.id
                )
            ]
        }
    }

    /// Smooths only the rendered curve while preserving stored samples and cycle boundaries.
    private var smoothedPoints: [QuotaHistoryChartPoint] {
        var result: [QuotaHistoryChartPoint] = []
        var cycleStart = series.points.startIndex

        while cycleStart < series.points.endIndex {
            let cycleID = series.points[cycleStart].cycleID
            var cycleEnd = series.points.index(after: cycleStart)
            while cycleEnd < series.points.endIndex,
                  series.points[cycleEnd].cycleID == cycleID {
                cycleEnd = series.points.index(after: cycleEnd)
            }

            result.append(contentsOf: smoothedCycle(Array(series.points[cycleStart..<cycleEnd])))
            cycleStart = cycleEnd
        }

        return result
    }

    private func smoothedCycle(_ points: [QuotaHistoryChartPoint]) -> [QuotaHistoryChartPoint] {
        guard points.count >= 3 else { return points }

        let weights: [Double] = [1, 4, 6, 4, 1]
        let weightTotal = weights.reduce(0, +)
        let lastIndex = points.index(before: points.endIndex)

        return points.indices.map { index in
            guard index > points.startIndex, index < lastIndex else {
                return points[index]
            }

            let weightedPercent = weights.enumerated().reduce(0.0) { total, element in
                let offset = element.offset - 2
                let sampleIndex = min(lastIndex, max(points.startIndex, index + offset))
                return total + (points[sampleIndex].remainingPercent * element.element)
            }
            let smoothedPercent = weightedPercent / weightTotal

            return QuotaHistoryChartPoint(
                id: points[index].id,
                date: points[index].date,
                remainingPercent: smoothedPercent,
                isSyntheticStart: points[index].isSyntheticStart,
                cycleID: points[index].cycleID
            )
        }
    }

    private func axisLabel(for date: Date, usesWeekday: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate(usesHourlyAxis ? "jm" : (usesWeekday ? "EEE" : "MMMd"))
        return formatter.string(from: date)
    }

    private var usesHourlyAxis: Bool {
        series.end.timeIntervalSince(series.start) <= 24 * 60 * 60
    }
}

extension View {
    /// Uses native Liquid Glass on macOS 26 while preserving the same modern
    /// layout with a material fallback on earlier supported systems.
    @ViewBuilder
    func historyGlassCard(cornerRadius: CGFloat = 22, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(
                interactive ? .regular.interactive() : .regular,
                in: .rect(cornerRadius: cornerRadius)
            )
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                }
        }
    }
}
