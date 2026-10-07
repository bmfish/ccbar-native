import SwiftUI
import Charts

// MARK: - 详情窗口图表（Swift Charts）
//
// 三个交互式图表：折线+面积（近7天）、柱状（近30天/每小时）。
// 统一支持拖选/悬停读数：竖直参考线 + 选中点的标签与数值。
// x 轴统一用零填充的字符串类别（排序即时间序），选中索引按比例换算。

struct ChartEntry: Equatable {
    let label: String
    let value: Int64
}

// 折线 + 面积（近7天）
struct LineTrendChart: View {
    let entries: [ChartEntry]
    var lineColor: NSColor = Design.brandColor

    @State private var selected: Int?

    var body: some View {
        Chart {
            ForEach(Array(entries.enumerated()), id: \.offset) { i, e in
                AreaMark(
                    x: .value("日", e.label),
                    y: .value("Token", e.value)
                )
                .foregroundStyle(.linearGradient(
                    colors: [Color(nsColor: lineColor).opacity(0.30),
                             Color(nsColor: lineColor).opacity(0.02)],
                    startPoint: .top, endPoint: .bottom
                ))
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("日", e.label),
                    y: .value("Token", e.value)
                )
                .foregroundStyle(Color(nsColor: lineColor))
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .interpolationMethod(.catmullRom)

                // 峰值点常驻小标记
                if e.value > 0, e.value == peakValue {
                    PointMark(
                        x: .value("日", e.label),
                        y: .value("Token", e.value)
                    )
                    .foregroundStyle(Color(nsColor: lineColor))
                    .symbolSize(20)
                    .opacity(0.9)
                }

                if selected == i {
                    PointMark(
                        x: .value("日", e.label),
                        y: .value("Token", e.value)
                    )
                    .foregroundStyle(Color(nsColor: lineColor))
                    .symbolSize(36)
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                AxisValueLabel().font(.system(size: 9))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                AxisValueLabel {
                    if let v = value.as(Int64.self) {
                        Text(Design.formatTokens(v)).font(.system(size: 9))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(dragGesture(width: geo.size.width))
                if let selected, selected < entries.count {
                    ruleLine(width: geo.size.width, index: selected)
                }
            }
        }
    }

    private var peakValue: Int64 {
        entries.map(\.value).max() ?? 0
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                selected = nearestIndex(x: value.location.x, width: width)
            }
            .onEnded { _ in }
    }

    private func ruleLine(width: CGFloat, index: Int) -> some View {
        let count = max(entries.count, 1)
        let x = (CGFloat(index) + 0.5) / CGFloat(count) * width
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.white.opacity(0.25))
                .frame(width: 1)
                .offset(x: x)
            Text("\(entries[index].label)  \(Design.formatTokens(entries[index].value))")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundColor(Color(nsColor: Design.textPrimary))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: Design.backgroundDark).opacity(0.9)))
                .offset(x: min(max(x - 50, 0), width - 120), y: 2)
        }
    }

    private func nearestIndex(x: CGFloat, width: CGFloat) -> Int? {
        guard !entries.isEmpty, width > 0 else { return nil }
        let frac = min(max(x / width, 0), 0.9999)
        return Int(frac * CGFloat(entries.count))
    }
}

// 柱状（近30天 / 每小时）
struct BarReadoutChart: View {
    let entries: [ChartEntry]
    /// 类别多时（如近30天）隐藏 x 轴标签，避免挤成一团
    var showXAxis = true

    @State private var selected: Int?

    var body: some View {
        Chart {
            ForEach(Array(entries.enumerated()), id: \.offset) { i, e in
                BarMark(
                    x: .value("序", e.label),
                    y: .value("Token", e.value)
                )
                .foregroundStyle(barColor(for: i))
                .cornerRadius(2)
            }
        }
        .chartXAxis {
            if showXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                    AxisValueLabel().font(.system(size: 9))
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                AxisValueLabel {
                    if let v = value.as(Int64.self) {
                        Text(Design.formatTokens(v)).font(.system(size: 9))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(dragGesture(width: geo.size.width))
                if let selected, selected < entries.count {
                    ruleLine(width: geo.size.width, index: selected)
                }
            }
        }
    }

    /// 每根柱子一个颜色：主题色板按位置取色（随机但稳定不闪变）
    private func barColor(for i: Int) -> Color {
        let palette = Design.modelColors(count: max(entries.count, 1))
        return Color(nsColor: palette[i % palette.count])
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                selected = nearestIndex(x: value.location.x, width: width)
            }
            .onEnded { _ in }
    }

    private func ruleLine(width: CGFloat, index: Int) -> some View {
        let count = max(entries.count, 1)
        let x = (CGFloat(index) + 0.5) / CGFloat(count) * width
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.white.opacity(0.25))
                .frame(width: 1)
                .offset(x: x)
            Text("\(entries[index].label)  \(Design.formatTokens(entries[index].value))")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundColor(Color(nsColor: Design.textPrimary))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: Design.backgroundDark).opacity(0.9)))
                .offset(x: min(max(x - 50, 0), max(width - 130, 0)), y: 2)
        }
    }

    private func nearestIndex(x: CGFloat, width: CGFloat) -> Int? {
        guard !entries.isEmpty, width > 0 else { return nil }
        let frac = min(max(x / width, 0), 0.9999)
        return Int(frac * CGFloat(entries.count))
    }
}
