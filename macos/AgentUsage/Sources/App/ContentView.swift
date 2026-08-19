import SwiftUI

struct ContentView: View {
    /// 本体ウィンドウとポップオーバーで、見出しと設定の出し方だけを変える。
    enum Variant {
        case window
        case popover

        var width: CGFloat { self == .popover ? 320 : 340 }
        /// ウィンドウはタイトルバーに名前が出るので、本文側では出さない。
        var showsTitle: Bool { self == .popover }
    }

    @EnvironmentObject private var store: UsageStore
    @EnvironmentObject private var display: DisplayPreferencesStore
    var variant: Variant = .window
    var openSettings: () -> Void = {}

    @State private var showsReloadConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if variant.showsTitle {
                Text("Agent Usage")
                    .font(.headline)
            }

            if let state = store.state {
                ForEach(visibleAgents(in: state), id: \.agent) { agent in
                    AgentSection(agent: agent, windowLabels: windowLabels(for: agent))
                }
            } else if let message = store.errorMessage {
                UsageErrorView(message: message)
                    .frame(minHeight: 72)
            } else {
                ProgressView("状態を読み込み中…")
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
            }

            if let message = store.errorMessage, store.state != nil {
                inlineError(message, symbol: "exclamationmark.triangle.fill")
            }

            if let mirrorError = store.mirrorError {
                inlineError(mirrorError, symbol: "widget.small.badge.exclamationmark")
            }

            footer
        }
        .padding(14)
        .frame(width: variant.width, alignment: .leading)
    }

    /// 最下部の操作行。左に設定、右にリロードと更新時刻を並べる。
    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: openSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
            }
            .help("設定")
            .accessibilityLabel("設定")

            Spacer(minLength: 8)

            Button(action: reload) {
                Image(systemName: reloadSymbol)
                    .font(.system(size: 12))
            }
            .help("状態ファイルを再読み込み")
            .accessibilityLabel("状態ファイルを再読み込み")

            if let updatedAt = store.state?.updatedAt {
                HStack(spacing: 6) {
                    Text(UsageFormat.freshness(updatedAt))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(UsageFormat.isStale(updatedAt) ? .orange : .secondary)
                    Text(UsageFormat.shortTime(updatedAt))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .accessibilityLabel("最終更新: \(UsageFormat.freshness(updatedAt))")
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    /// 設定で 1 枠も選ばれていないエージェントは一覧から省く。
    private func visibleAgents(in state: UsageState) -> [UsageState.Agent] {
        state.orderedAgents.filter { !windowLabels(for: $0).isEmpty }
    }

    /// 選択肢はメニューバー・ウィジェットと同じく、共通の 5h / 7d に state.json 固有の枠を足したもの。
    private func windowLabels(for agent: UsageState.Agent) -> [String] {
        let extras = agent.orderedWindows
            .map(\.label)
            .filter { !DisplayPreferences.commonWindows.contains($0) }
        return display.windows(
            scope: .app,
            agentID: agent.agent,
            available: DisplayPreferences.commonWindows + extras
        )
    }

    private func inlineError(_ message: String, symbol: String) -> some View {
        Label(message, systemImage: symbol)
            .font(.system(size: 10))
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var reloadSymbol: String {
        if store.isSyncing { return "arrow.triangle.2.circlepath" }
        return showsReloadConfirmation ? "checkmark" : "arrow.clockwise"
    }

    private func reload() {
        store.forceSync()
        showsReloadConfirmation = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            showsReloadConfirmation = false
        }
    }
}
