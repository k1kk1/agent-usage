import ServiceManagement
import SwiftUI

/// 設定ウィンドウ。表示する枠の選択と、起動・通知の設定をまとめる。
struct SettingsView: View {
    @EnvironmentObject private var store: UsageStore
    @EnvironmentObject private var alerts: UsageAlertManager
    @EnvironmentObject private var display: DisplayPreferencesStore

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    /// 入力途中の文字列。数値や日付は打ち終わるまで解釈できないので、
    /// 画面側の下書きを持ち、解釈できたものだけ設定へ書き戻す。
    @State private var drafts: [String: PlanDraft] = [:]

    private struct PlanDraft: Equatable {
        var period: String
        var anchor: String
        var limit: String

        init(plan: DisplayPreferences.TokenPlan) {
            period = "\(plan.periodDays)"
            anchor = plan.anchorDate ?? ""
            limit = UsageFormat.tokensInput(plan.limit)
        }
    }

    var body: some View {
        ScrollView {
            content
        }
        // 表示先が 3 つ・エージェントが 2 つ並ぶと縦に伸びるので、画面からはみ出さない高さで止める。
        .frame(width: 320, height: 560)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(DisplayPreferences.Scope.allCases, id: \.self) { scope in
                scopeSection(scope)
            }

            Divider()

            tokenPlanSection

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
        .frame(width: 320, alignment: .leading)
    }

    /// トークンの集計期間と上限。表示先ではなく契約側の都合なので、表示先の選択とは分けて置く。
    private var tokenPlanSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("トークンの集計")
                .font(.system(size: 12, weight: .semibold))

            ForEach(agents, id: \.agent) { agent in
                let plan = display.plan(agentID: agent.agent)
                let draft = binding(for: agent.agent)

                VStack(alignment: .leading, spacing: 4) {
                    Label {
                        Text(agent.label)
                            .font(.system(size: 11, weight: .medium))
                    } icon: {
                        AgentIconView(agentID: agent.agent, size: 11)
                            .foregroundStyle(.secondary)
                    }

                    field("集計期間", text: draft.period, width: 52, suffix: "日", placeholder: "1")
                    field(
                        "更新日",
                        text: draft.anchor,
                        width: 96,
                        suffix: nil,
                        placeholder: "yyyy-MM-dd"
                    )
                    field("上限", text: draft.limit, width: 72, suffix: "トークン", placeholder: "上限なし")

                    Text(planSummary(plan))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 18)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func field(
        _ title: String,
        text: Binding<String>,
        width: CGFloat,
        suffix: String?,
        placeholder: String
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11))
                .frame(width: 56, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: width)
            if let suffix {
                Text(suffix)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 18)
    }

    /// いま合算している期間と、上限があれば残り日数を添える。
    private func planSummary(_ plan: DisplayPreferences.TokenPlan) -> String {
        let range = TokenPeriod.range(plan: plan)
        let period = plan.periodDays <= 1
            ? "当日（\(TokenPeriod.text(range.start))）を集計"
            : "\(TokenPeriod.text(range.start)) 〜 \(TokenPeriod.text(range.end)) を集計"
        let reset = plan.anchorDate == nil
            ? "毎日更新"
            : "残り \(TokenPeriod.remainingDays(plan: plan)) 日"
        return "\(period)・\(reset)"
    }

    private func binding(for agentID: String) -> (period: Binding<String>, anchor: Binding<String>, limit: Binding<String>) {
        func draft() -> PlanDraft {
            drafts[agentID] ?? PlanDraft(plan: display.plan(agentID: agentID))
        }
        func update(_ transform: @escaping (inout PlanDraft) -> Void) {
            var next = draft()
            transform(&next)
            drafts[agentID] = next
            commit(next, agentID: agentID)
        }
        return (
            Binding(get: { draft().period }, set: { value in update { $0.period = value } }),
            Binding(get: { draft().anchor }, set: { value in update { $0.anchor = value } }),
            Binding(get: { draft().limit }, set: { value in update { $0.limit = value } })
        )
    }

    /// 解釈できた項目だけ保存する。入力途中の空欄や不正な日付で設定を壊さない。
    private func commit(_ draft: PlanDraft, agentID: String) {
        var plan = display.plan(agentID: agentID)
        if let days = Int(draft.period.trimmingCharacters(in: .whitespaces)), days >= 1 {
            plan.periodDays = days
        }
        let anchor = draft.anchor.trimmingCharacters(in: .whitespaces)
        plan.anchorDate = anchor.isEmpty ? nil : (TokenPeriod.day(anchor) != nil ? anchor : nil)
        plan.limit = UsageFormat.parseTokens(draft.limit)
        display.setPlan(plan, agentID: agentID)
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
