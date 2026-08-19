import SwiftUI

enum UsagePalette {
    /// pane 版と同じしきい値: 80% 以上で赤、50% 以上で橙、それ未満は緑。
    static func color(for pct: Double?) -> Color {
        guard let pct else { return .secondary }
        if pct >= 80 { return .red }
        if pct >= 50 { return .orange }
        return .green
    }
}

/// エージェントごとの SF Symbols 名。メニューバーと一覧で同じ絵柄を使う。
enum AgentSymbol {
    static func name(for agentID: String?) -> String {
        switch agentID {
        case "claude": return "sparkles"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        default: return "gauge.with.dots.needle.33percent"
        }
    }
}

enum UsageFormat {
    /// daemon が書く "2026-07-31 17:20:00 JST" 形式。
    private static let stateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss 'JST'"
        return f
    }()

    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return stateFormatter.date(from: text)
    }

    /// "2026-07-31 17:20:00 JST" → "07/31 17:20"。解釈できない場合は原文を返す。
    static func shortTime(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "--" }
        guard let date = stateFormatter.date(from: text) else { return text }
        return shortFormatter.string(from: date)
    }

    static func percent(_ pct: Double?) -> String {
        guard let pct else { return "--%" }
        return String(format: "%.0f%%", pct)
    }

    /// トークン数は桁が大きく毎回変わるので、幅が動かないよう 4 文字前後に丸める。
    /// 1234567 → "1.2M"、12345 → "12k"。
    static func tokens(_ count: Int?) -> String {
        guard let count else { return "--" }
        let value = Double(count)
        switch abs(count) {
        case 1_000_000...:
            return String(format: "%.1fM", value / 1_000_000)
        case 10_000...:
            return String(format: "%.0fk", value / 1_000)
        case 1_000...:
            return String(format: "%.1fk", value / 1_000)
        default:
            return "\(count)"
        }
    }

    /// 単価表を持たないエージェント（Codex）では nil になる。
    static func cost(_ usd: Double?) -> String? {
        guard let usd else { return nil }
        return usd >= 10
            ? String(format: "$%.0f", usd)
            : String(format: "$%.2f", usd)
    }

    static func freshness(_ text: String?, now: Date = Date()) -> String {
        guard let date = date(text) else { return "更新時刻不明" }
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "たった今"
        case ..<3_600: return "\(Int(seconds / 60))分前"
        case ..<86_400: return "\(Int(seconds / 3_600))時間前"
        default: return "\(Int(seconds / 86_400))日前"
        }
    }

    static func isStale(_ text: String?, after seconds: TimeInterval = 150, now: Date = Date()) -> Bool {
        guard let date = date(text) else { return true }
        return now.timeIntervalSince(date) > seconds
    }
}

/// 使用率バー 1 本。
struct UsageBar: View {
    let pct: Double?
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let ratio = min(max((pct ?? 0) / 100, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(UsagePalette.color(for: pct))
                    .frame(width: geo.size.width * ratio)
            }
        }
        .frame(height: height)
    }
}

/// "5h [====----] 47% 07/31 17:20" 相当の 1 行。
struct UsageWindowRow: View {
    let window: UsageState.Window
    var showsReset: Bool = true

    var body: some View {
        HStack(spacing: 6) {
            Text(window.label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .leading)

            UsageBar(pct: window.usedPct)

            Text(UsageFormat.percent(window.usedPct))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(UsagePalette.color(for: window.usedPct))
                .frame(width: 34, alignment: .trailing)

            if showsReset {
                Text(UsageFormat.shortTime(window.resetAt))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 62, alignment: .trailing)
            }
        }
    }
}

/// 日別トークン数の推移。ウィジェット拡張でも描くので、外部依存を持たない Path で引く。
struct Sparkline: View {
    let values: [Int]
    var height: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let maximum = values.max() ?? 0
            if values.count >= 2, maximum > 0 {
                let step = geo.size.width / CGFloat(values.count - 1)
                Path { path in
                    for (index, value) in values.enumerated() {
                        // 0 が底、最大値が上端。値の絶対量ではなく推移を見せる。
                        let ratio = CGFloat(value) / CGFloat(maximum)
                        let point = CGPoint(
                            x: CGFloat(index) * step,
                            y: geo.size.height * (1 - ratio)
                        )
                        if index == 0 {
                            path.move(to: point)
                        } else {
                            path.addLine(to: point)
                        }
                    }
                }
                .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1, lineJoin: .round))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// "today  1.2M  ~$4.31" 相当の 1 行。UsageWindowRow と行の高さを揃える。
struct TokenRow: View {
    let label: String
    let bucket: UsageState.TokenUsage.Bucket?
    var daily: [Int] = []
    /// 幅の狭いウィジェットでは内訳とスパークラインを省く。
    var showsDetail: Bool = true

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)

            Text(UsageFormat.tokens(bucket?.total))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .frame(width: 44, alignment: .trailing)

            if showsDetail, daily.count >= 2 {
                Sparkline(values: daily)
            } else {
                Spacer(minLength: 0)
            }

            if let cost = UsageFormat.cost(bucket?.costUsd) {
                Text(cost)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 46, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = ["\(label) \(UsageFormat.tokens(bucket?.total)) トークン"]
        if let bucket {
            parts.append("入力 \(UsageFormat.tokens(bucket.input))")
            parts.append("出力 \(UsageFormat.tokens(bucket.output))")
            parts.append("キャッシュ \(UsageFormat.tokens(bucket.cacheRead + bucket.cacheWrite))")
        }
        if let cost = UsageFormat.cost(bucket?.costUsd) {
            parts.append("概算 \(cost)")
        }
        return parts.joined(separator: "、")
    }
}

/// エージェント 1 つ分のブロック。取得失敗時はバーの代わりにステータスを赤字で出す。
struct AgentSection: View {
    let agent: UsageState.Agent
    var showsReset: Bool = true
    /// 表示する枠のラベル。nil なら state.json にある枠をすべて出す。
    /// 指定した枠が state.json に無い場合は、未取得として `--%` の行を出す。
    var windowLabels: [String]?
    /// 枠の下に出すトークン行。空なら出さない。
    var metrics: [DisplayPreferences.Metric] = []
    /// 狭い面ではスパークラインと内訳を省く。
    var showsMetricDetail: Bool = true

    private func visible(_ windows: [UsageState.Window]) -> [UsageState.Window] {
        guard let windowLabels else { return windows }
        return windowLabels.map { label in
            windows.first { $0.label == label }
                ?? UsageState.Window(label: label, usedPct: nil, resetAt: nil)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(agent.label)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            } icon: {
                AgentIconView(agentID: agent.agent, size: 11)
                    .foregroundStyle(.secondary)
            }
            .labelStyle(.titleAndIcon)

            if agent.isOK {
                // 枠を 1 つも選んでいなくてもトークンだけ出したい場合があるので、
                // 空でもエラー表示には落とさない。
                ForEach(visible(agent.orderedWindows), id: \.label) { window in
                    UsageWindowRow(window: window, showsReset: showsReset)
                }
            } else if agent.hasStaleUsage {
                Text("取得失敗・前回の成功値")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                ForEach(visible(agent.orderedLastSuccessWindows), id: \.label) { window in
                    UsageWindowRow(window: window, showsReset: showsReset)
                        .opacity(0.5)
                }
                Text(agent.statusText)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                Text(agent.statusText)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            // トークンはローカルのログ由来で、利用枠の取得が失敗していても残る。
            // status に関係なく出す。
            tokenRows
        }
    }

    @ViewBuilder
    private var tokenRows: some View {
        if !metrics.isEmpty, let usage = agent.usage {
            let daily = usage.daily.map(\.total)
            ForEach(metrics, id: \.self) { metric in
                switch metric {
                case .tokensToday:
                    TokenRow(
                        label: metric.rowLabel,
                        bucket: usage.today,
                        daily: daily,
                        showsDetail: showsMetricDetail
                    )
                case .tokensSession:
                    TokenRow(
                        label: metric.rowLabel,
                        bucket: usage.session,
                        showsDetail: false
                    )
                }
            }
        }
    }
}

/// 読み込み失敗時の共通表示。
struct UsageErrorView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Agent Usage")
                .font(.system(size: 11, weight: .semibold))
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
