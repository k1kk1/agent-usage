import ServiceManagement
import SwiftUI

/// 設定ウィンドウ。表示する枠の選択と、起動・通知の設定をまとめる。
struct SettingsView: View {
    @EnvironmentObject private var store: UsageStore
    @EnvironmentObject private var alerts: UsageAlertManager
    @EnvironmentObject private var display: DisplayPreferencesStore

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(DisplayPreferences.Scope.allCases, id: \.self) { scope in
                scopeSection(scope)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("ログイン時に起動", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLaunchAtLogin(enabled)
                    }

                Toggle("80%・95%で通知", isOn: $alerts.enabled)

                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 11))

            Text("メニューバーを右クリックしても、表示する項目と終了を選べます。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
    }

    private func scopeSection(_ scope: DisplayPreferences.Scope) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(scope.title)
                .font(.system(size: 12, weight: .semibold))

            if agents.isEmpty {
                Text("状態ファイルを読み込めていません。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            ForEach(agents, id: \.agent) { agent in
                VStack(alignment: .leading, spacing: 4) {
                    Label {
                        Text(agent.label)
                            .font(.system(size: 11, weight: .medium))
                    } icon: {
                        AgentIconView(agentID: agent.agent, size: 11)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(windowLabels(for: agent), id: \.self) { label in
                        windowToggle(scope: scope, agent: agent, window: label)
                    }

                    ForEach(DisplayPreferences.Metric.allCases, id: \.self) { metric in
                        metricToggle(scope: scope, agent: agent, metric: metric)
                    }
                }
            }
        }
    }

    private func metricToggle(
        scope: DisplayPreferences.Scope,
        agent: UsageState.Agent,
        metric: DisplayPreferences.Metric
    ) -> some View {
        let binding = Binding(
            get: { display.isSelected(scope: scope, agentID: agent.agent, metric: metric) },
            set: { _ in display.toggle(scope: scope, agentID: agent.agent, metric: metric) }
        )

        return Toggle(isOn: binding) {
            Text(metric.title)
                .font(.system(size: 11))
        }
        .toggleStyle(.checkbox)
        .padding(.leading, 18)
    }

    private func windowToggle(
        scope: DisplayPreferences.Scope,
        agent: UsageState.Agent,
        window: String
    ) -> some View {
        let available = windowLabels(for: agent)
        let binding = Binding(
            get: { display.isSelected(scope: scope, agentID: agent.agent, window: window) },
            set: { _ in
                display.toggle(
                    scope: scope,
                    agentID: agent.agent,
                    window: window,
                    available: available
                )
            }
        )

        return Toggle(isOn: binding) {
            Text(window)
                .font(.system(size: 11, design: .monospaced))
        }
        .toggleStyle(.checkbox)
        .padding(.leading, 18)
    }

    private var agents: [UsageState.Agent] {
        store.state?.orderedAgents ?? []
    }

    /// 選択肢は UI を揃えるため共通の 5h / 7d に、state.json 固有の枠を足したもの。
    private func windowLabels(for agent: UsageState.Agent) -> [String] {
        let extras = agent.orderedWindows
            .map(\.label)
            .filter { !DisplayPreferences.commonWindows.contains($0) }
        return DisplayPreferences.commonWindows + extras
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
