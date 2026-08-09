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

/// エージェント 1 つ分のブロック。取得失敗時はバーの代わりにステータスを赤字で出す。
struct AgentSection: View {
    let agent: UsageState.Agent
    var showsReset: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(agent.label)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)

            if agent.isOK, !agent.orderedWindows.isEmpty {
                ForEach(agent.orderedWindows, id: \.label) { window in
                    UsageWindowRow(window: window, showsReset: showsReset)
                }
            } else if agent.hasStaleUsage {
                Text("取得失敗・前回の成功値")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                ForEach(agent.orderedLastSuccessWindows, id: \.label) { window in
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
