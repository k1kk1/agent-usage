import Foundation
import SwiftUI
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let state: UsageState?
    let errorMessage: String?
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
        switch UsageStateLoader.loadMirror() {
        case .success(let state):
            return UsageEntry(date: Date(), state: state, errorMessage: nil)
        case .failure(let error):
            return UsageEntry(date: Date(), state: nil, errorMessage: error.localizedDescription)
        }
    }
}

struct AgentUsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    private var showsReset: Bool { family != .systemSmall }

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

            ForEach(state.orderedAgents, id: \.agent) { agent in
                AgentSection(agent: agent, showsReset: showsReset)
            }

            if family == .systemLarge {
                Divider()
                largeDetails(for: state)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func largeDetails(for state: UsageState) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(state.orderedAgents, id: \.agent) { agent in
                if let context = agent.context?.usedPct {
                    Text("\(agent.label) context \(UsageFormat.percent(context))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if let cost = agent.cost?.totalUsd {
                    Text("\(agent.label) session $\(String(format: "%.4f", cost))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
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
