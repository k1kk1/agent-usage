import Foundation
import SwiftUI
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let state: UsageState?
    let errorMessage: String?
    var preferences: DisplayPreferences = .standard
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), state: nil, errorMessage: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        // ミラーファイルを更新できるのはホストアプリだけなので、短い定期更新は不要。
        // ホスト側が変更を検知した時だけ reloadTimelines(ofKind:) を呼ぶ。
        completion(Timeline(entries: [makeEntry()], policy: .never))
    }

    private func makeEntry() -> UsageEntry {
        let preferences = DisplayPreferences.loadMirror()
        switch UsageStateLoader.loadMirror() {
        case .success(let state):
            return UsageEntry(date: Date(), state: state, errorMessage: nil, preferences: preferences)
        case .failure(let error):
            return UsageEntry(
                date: Date(),
                state: nil,
                errorMessage: error.localizedDescription,
                preferences: preferences
            )
        }
    }
}

struct AgentUsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    private var showsReset: Bool { family != .systemSmall }

    /// グラフを出せるかは縦の余白で決まる。
    /// Small は幅も高さも足りない。Medium はエージェント 1 つぶんしか入らないので、
    /// 2 つ並ぶときは枠とトークン行を優先してグラフを省く。Large は常に入る。
    private func showsChart(agentCount: Int) -> Bool {
        switch family {
        case .systemSmall: return false
        case .systemLarge: return true
        default: return agentCount <= 1
        }
    }

    var body: some View {
        Group {
            if let state = entry.state {
                content(for: state)
            } else if let message = entry.errorMessage {
                UsageErrorView(message: message)
            } else {
                UsageErrorView(message: "読み込み中…")
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func content(for state: UsageState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Agent Usage")
                    .font(.system(size: 11, weight: .bold))
                Spacer(minLength: 4)
                Text(UsageFormat.freshness(state.updatedAt))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(UsageFormat.isStale(state.updatedAt) ? Color.orange : Color.secondary)
            }

            let agents = visibleAgents(in: state)
            ForEach(agents, id: \.agent) { agent in
                AgentSection(
                    agent: agent,
                    showsReset: showsReset,
                    windowLabels: windowLabels(for: agent),
                    metrics: entry.preferences.metrics(scope: .widget, agentID: agent.agent),
                    plan: entry.preferences.plan(agentID: agent.agent),
                    showsChart: showsChart(agentCount: agents.count),
                    // Large は縦に余裕があるので、アプリと同じ高さで出す。
                    compactChart: family != .systemLarge
                )
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 設定で枠も表示項目も選ばれていないエージェントはウィジェットから省く。
    private func visibleAgents(in state: UsageState) -> [UsageState.Agent] {
        state.orderedAgents.filter {
            !windowLabels(for: $0).isEmpty
                || !entry.preferences.metrics(scope: .widget, agentID: $0.agent).isEmpty
        }
    }

    /// 選択肢はメニューバー側と同じく、共通の 5h / 7d に state.json 固有の枠を足したもの。
    private func windowLabels(for agent: UsageState.Agent) -> [String] {
        let extras = agent.orderedWindows
            .map(\.label)
            .filter { !DisplayPreferences.commonWindows.contains($0) }
        return entry.preferences.windows(
            scope: .widget,
            agentID: agent.agent,
            available: DisplayPreferences.commonWindows + extras
        )
    }

}

struct AgentUsageWidget: Widget {
    let kind = "AgentUsageWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageProvider()) { entry in
            AgentUsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Agent Usage")
        .description("Claude Code と Codex の利用枠を表示します。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct AgentUsageWidgetBundle: WidgetBundle {
    var body: some Widget {
        AgentUsageWidget()
    }
}
