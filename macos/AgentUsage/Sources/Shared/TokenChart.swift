import SwiftUI

/// 日別トークン数の棒グラフ。
///
/// 折れ線を自分自身の最大値で正規化すると、120k の日と 250M の日が同じ形になり
/// 「多いのか少ないのか」が読めない。ここでは 0 を底にした実数スケールで棒を並べ、
/// 比較の相手（1 日あたりの目安）を点線で重ねる。
struct DailyBarChart: View {
    let series: [(date: Date, total: Int)]
    /// 点線を引く基準値。上限があればそれを期間日数で割った値、無ければ 5h 枠の実測見積り。
    /// どちらも取れないときは nil で、期間中の最大値を基準に灰色で描く。
    var allowance: Int?

    /// 棒の高さ。ウィジェットのように縦が詰まる面では低くする。
    var height: CGFloat = 34
    /// ホバーで読む行。ホバーの無いウィジェットでは出さない。
    var showsDetail: Bool = true

    /// マウスが乗っている棒。乗っていない間は最新日を出す。
    @State private var hovered: Int?

    private var maximum: Int {
        max(series.map(\.total).max() ?? 0, allowance ?? 0)
    }

    /// 目安線が天井に張り付くと超過分が描けないので、少し余裕を持たせる。
    private var scale: Double {
        Double(maximum) * 1.1
    }

    private var focused: (date: Date, total: Int)? {
        guard let index = hovered ?? series.indices.last, series.indices.contains(index) else {
            return nil
        }
        return series[index]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if showsDetail {
                detailLine
            }

            HStack(alignment: .top, spacing: 6) {
                Text(referenceLabel)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 56, alignment: .trailing)

                bars
            }

            // 横軸は端の 2 日だけ。目盛りを増やすより、期間の両端がわかれば足りる。
            HStack(spacing: 0) {
                Spacer().frame(width: 62)
                Text(UsageFormat.monthDay(series.first?.date))
                Spacer(minLength: 0)
                Text(UsageFormat.monthDay(series.last?.date))
            }
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var referenceLabel: String {
        guard let allowance else { return UsageFormat.tokens(maximum) }
        return "\(UsageFormat.tokens(allowance)) / 日"
    }

    /// 棒に重ねる吹き出しは幅を食うので、グラフの上に 1 行だけ置く。
    /// ホバーしていない間も最新日を出しておけば、行の高さが動かない。
    private var detailLine: some View {
        HStack(spacing: 6) {
            if let focused {
                Text(UsageFormat.monthDay(focused.date))
                    .foregroundStyle(hovered == nil ? .tertiary : .secondary)
                Text(UsageFormat.tokens(focused.total))
                    .fontWeight(.semibold)
                    .foregroundStyle(barColor(for: focused.total, isFocused: true))
                if let pct = pct(for: focused.total) {
                    Text("目安の \(UsageFormat.percent(pct))")
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 9, design: .monospaced))
        .padding(.leading, 62)
    }

    private var bars: some View {
        GeometryReader { geo in
            let count = max(1, series.count)
            let spacing: CGFloat = series.count > 20 ? 1 : 2
            let slot = geo.size.width / CGFloat(count)
            let barWidth = max(1, slot - spacing)

            ZStack(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(Array(series.enumerated()), id: \.offset) { index, entry in
                        let ratio = scale > 0 ? min(Double(entry.total) / scale, 1) : 0
                        RoundedRectangle(cornerRadius: 1)
                            .fill(barColor(for: entry.total, isFocused: index == hovered))
                            // 0 の日も「記録があって 0」だとわかるよう、1px の下地を残す。
                            .frame(width: barWidth, height: max(1, geo.size.height * ratio))
                    }
                }

                if let allowance, scale > 0 {
                    let y = geo.size.height * (1 - min(Double(allowance) / scale, 1))
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }

                if let hovered, series.indices.contains(hovered) {
                    // どの棒を読んでいるかを示す縦の帯。棒より薄くして値を隠さない。
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: slot)
                        .offset(x: slot * CGFloat(hovered))
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let index = Int(point.x / max(1, slot))
                    hovered = series.indices.contains(index) ? index : nil
                case .ended:
                    hovered = nil
                }
            }
        }
        .frame(height: height)
    }

    private func pct(for total: Int) -> Double? {
        guard let allowance, allowance > 0 else { return nil }
        return Double(total) / Double(allowance) * 100
    }

    /// 目安以内は緑、超えたら黄、2 倍以上で赤。目安が取れないときは灰色で量だけを見せる。
    private func barColor(for total: Int, isFocused: Bool) -> Color {
        guard let pct = pct(for: total) else {
            return Color.secondary.opacity(isFocused ? 0.9 : 0.4)
        }
        return UsagePalette.allowanceColor(for: pct).opacity(isFocused ? 1 : 0.7)
    }

    private var accessibilityText: String {
        let totals = series.map(\.total)
        var parts = ["日別トークン \(series.count) 日ぶん"]
        parts.append("最大 \(UsageFormat.tokens(totals.max()))")
        if !totals.isEmpty {
            parts.append("平均 \(UsageFormat.tokens(totals.reduce(0, +) / totals.count))")
        }
        if let allowance {
            parts.append("1 日の目安 \(UsageFormat.tokens(allowance))")
        }
        return parts.joined(separator: "、")
    }
}
