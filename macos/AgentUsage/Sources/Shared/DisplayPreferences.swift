import Foundation

/// アプリ・メニューバー・ウィジェットに出す利用枠の選択。
/// ウィジェットは App Sandbox 下で UserDefaults を共有できないため、state.json と同じく
/// ホストアプリがウィジェットのコンテナへ JSON をミラーして渡す。
struct DisplayPreferences: Codable, Equatable {
    enum Scope: String, CaseIterable, Codable {
        case app
        case menuBar
        case widget

        var title: String {
            switch self {
            case .app: return "アプリに表示する項目"
            case .menuBar: return "メニューバーに表示する項目"
            case .widget: return "ウィジェットに表示する項目"
            }
        }
    }

    /// 利用枠とは別軸の表示項目。枠は「5h」「7d」のようにエージェントが返す単位だが、
    /// トークンは枠ではないため、枠の選択に混ぜず独立した選択肢として持つ。
    enum Metric: String, CaseIterable, Codable {
        /// 集計期間（既定は当日）のトークン。raw 値は保存済み設定と互換を保つため据え置く。
        case tokensPeriod = "tokensToday"
        case tokensSession

        var title: String {
            switch self {
            case .tokensPeriod: return "期間内のトークン"
            case .tokensSession: return "セッションのトークン"
            }
        }

        /// 行の左端に出す短いラベル。期間が 1 日なら "today"、N 日なら "Nd"。
        func rowLabel(plan: TokenPlan) -> String {
            switch self {
            case .tokensPeriod: return plan.periodDays <= 1 ? "today" : "\(plan.periodDays)d"
            case .tokensSession: return "session"
            }
        }
    }

    /// トークンの集計期間と上限。エージェントごとに持つ。
    /// 利用枠（5h/7d）と違い API からは取れないので、利用側の契約に合わせて手で設定する。
    struct TokenPlan: Codable, Equatable {
        /// 集計する日数。1 なら当日のみ。
        var periodDays: Int
        /// 集計期間の起点となる日（yyyy-MM-dd, JST）。
        /// Codex の PAT のように「N 日ごとに決まった日で更新される」枠に合わせるためのもの。
        /// nil なら常に今日を末日とする直近 N 日。
        var anchorDate: String?
        /// トークン上限。nil または 0 以下なら上限なしとして色分けしない。
        var limit: Int?

        static let standard = TokenPlan(periodDays: 1, anchorDate: nil, limit: nil)

        init(periodDays: Int = 1, anchorDate: String? = nil, limit: Int? = nil) {
            self.periodDays = max(1, periodDays)
            self.anchorDate = anchorDate
            self.limit = limit
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            periodDays = max(1, try container.decodeIfPresent(Int.self, forKey: .periodDays) ?? 1)
            anchorDate = try container.decodeIfPresent(String.self, forKey: .anchorDate)
            limit = try container.decodeIfPresent(Int.self, forKey: .limit)
        }

        /// 上限として意味のある値だけを返す。
        var effectiveLimit: Int? {
            guard let limit, limit > 0 else { return nil }
            return limit
        }
    }

    /// 表示先ごとに `エージェントID: [枠ラベル]`。
    var app: [String: [String]]
    var menuBar: [String: [String]]
    var widget: [String: [String]]

    /// 表示先ごとに `エージェントID: [表示項目]`。
    var appMetrics: [String: [Metric]]
    var menuBarMetrics: [String: [Metric]]
    var widgetMetrics: [String: [Metric]]

    /// `エージェントID: 集計期間と上限`。表示先によらず共通。
    var tokenPlans: [String: TokenPlan]

    /// エージェントが返す枠に関わらず、選択肢として常に並べる枠。
    static let commonWindows = ["5h", "7d"]

    private static let allWindows = ["claude": commonWindows, "codex": commonWindows]

    private static let defaultAppMetrics: [String: [Metric]] = [
        "claude": [.tokensPeriod, .tokensSession],
        "codex": [.tokensPeriod]
    ]
    private static let defaultWidgetMetrics: [String: [Metric]] = [
        "claude": [.tokensPeriod],
        "codex": [.tokensPeriod]
    ]
    /// メニューバーは横幅が貴重なので、既定ではトークンを出さない。
    private static let defaultMenuBarMetrics: [String: [Metric]] = [:]

    static let standard = DisplayPreferences(
        app: allWindows,
        menuBar: ["claude": ["5h"], "codex": ["7d"]],
        widget: allWindows,
        appMetrics: defaultAppMetrics,
        menuBarMetrics: defaultMenuBarMetrics,
        widgetMetrics: defaultWidgetMetrics,
        tokenPlans: [:]
    )

    /// 保存済みの JSON に新しい表示先のキーが無くても、既存の設定を捨てずに読む。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        app = try container.decodeIfPresent([String: [String]].self, forKey: .app)
            ?? DisplayPreferences.allWindows
        menuBar = try container.decodeIfPresent([String: [String]].self, forKey: .menuBar)
            ?? ["claude": ["5h"], "codex": ["7d"]]
        widget = try container.decodeIfPresent([String: [String]].self, forKey: .widget)
            ?? DisplayPreferences.allWindows
        appMetrics = try container.decodeIfPresent([String: [Metric]].self, forKey: .appMetrics)
            ?? DisplayPreferences.defaultAppMetrics
        menuBarMetrics = try container.decodeIfPresent([String: [Metric]].self, forKey: .menuBarMetrics)
            ?? DisplayPreferences.defaultMenuBarMetrics
        widgetMetrics = try container.decodeIfPresent([String: [Metric]].self, forKey: .widgetMetrics)
            ?? DisplayPreferences.defaultWidgetMetrics
        tokenPlans = try container.decodeIfPresent([String: TokenPlan].self, forKey: .tokenPlans) ?? [:]
    }

    init(
        app: [String: [String]],
        menuBar: [String: [String]],
        widget: [String: [String]],
        appMetrics: [String: [Metric]] = [:],
        menuBarMetrics: [String: [Metric]] = [:],
        widgetMetrics: [String: [Metric]] = [:],
        tokenPlans: [String: TokenPlan] = [:]
    ) {
        self.app = app
        self.menuBar = menuBar
        self.widget = widget
        self.appMetrics = appMetrics
        self.menuBarMetrics = menuBarMetrics
        self.widgetMetrics = widgetMetrics
        self.tokenPlans = tokenPlans
    }

    /// 未設定のエージェントは既定（当日集計・上限なし）。
    func plan(agentID: String) -> TokenPlan {
        tokenPlans[agentID] ?? .standard
    }

    mutating func setPlan(_ plan: TokenPlan, agentID: String) {
        tokenPlans[agentID] = plan
    }

    subscript(scope: Scope) -> [String: [String]] {
        get {
            switch scope {
            case .app: return app
            case .menuBar: return menuBar
            case .widget: return widget
            }
        }
        set {
            switch scope {
            case .app: app = newValue
            case .menuBar: menuBar = newValue
            case .widget: widget = newValue
            }
        }
    }

    /// 選択されている枠を、`available`（state.json にある枠）の順で返す。
    /// 未設定のエージェントは既定値、既定値も無ければ全枠を出す。
    func windows(scope: Scope, agentID: String, available: [String]) -> [String] {
        let selection = self[scope][agentID]
            ?? DisplayPreferences.standard[scope][agentID]
            ?? available
        return available.filter(selection.contains)
    }

    /// 表示先ごとの表示項目。枠と違い state.json 側の並びに合わせる必要がないので、
    /// 定義順（Metric.allCases）で安定させる。
    subscript(metrics scope: Scope) -> [String: [Metric]] {
        get {
            switch scope {
            case .app: return appMetrics
            case .menuBar: return menuBarMetrics
            case .widget: return widgetMetrics
            }
        }
        set {
            switch scope {
            case .app: appMetrics = newValue
            case .menuBar: menuBarMetrics = newValue
            case .widget: widgetMetrics = newValue
            }
        }
    }

    func metrics(scope: Scope, agentID: String) -> [Metric] {
        let selection = self[metrics: scope][agentID]
            ?? DisplayPreferences.standard[metrics: scope][agentID]
            ?? []
        return Metric.allCases.filter(selection.contains)
    }

    func isSelected(scope: Scope, agentID: String, metric: Metric) -> Bool {
        metrics(scope: scope, agentID: agentID).contains(metric)
    }

    mutating func toggle(scope: Scope, agentID: String, metric: Metric) {
        var selection = metrics(scope: scope, agentID: agentID)
        if let index = selection.firstIndex(of: metric) {
            selection.remove(at: index)
        } else {
            selection.append(metric)
        }
        self[metrics: scope][agentID] = Metric.allCases.filter(selection.contains)
    }

    func isSelected(scope: Scope, agentID: String, window: String) -> Bool {
        let selection = self[scope][agentID] ?? DisplayPreferences.standard[scope][agentID]
        // 既定にも無いエージェントは全選択とみなす。
        guard let selection else { return true }
        return selection.contains(window)
    }

    mutating func toggle(scope: Scope, agentID: String, window: String, available: [String]) {
        var selection = self[scope][agentID]
            ?? DisplayPreferences.standard[scope][agentID]
            ?? available
        if let index = selection.firstIndex(of: window) {
            selection.remove(at: index)
        } else {
            selection.append(window)
        }
        // 保存順は選択肢の並びに合わせる。
        self[scope][agentID] = available.filter(selection.contains)
    }

    /// ウィジェット用。ホストアプリが書いたミラーを読む。見つからなければ既定値。
    static func loadMirror() -> DisplayPreferences {
        guard
            let data = try? Data(contentsOf: SharedPaths.widgetPreferencesURL),
            let decoded = try? JSONDecoder().decode(DisplayPreferences.self, from: data)
        else { return .standard }
        return decoded
    }
}
