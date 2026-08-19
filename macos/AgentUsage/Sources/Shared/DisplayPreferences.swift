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
            case .app: return "アプリに表示する枠"
            case .menuBar: return "メニューバーに表示する枠"
            case .widget: return "ウィジェットに表示する枠"
            }
        }
    }

    /// 表示先ごとに `エージェントID: [枠ラベル]`。
    var app: [String: [String]]
    var menuBar: [String: [String]]
    var widget: [String: [String]]

    /// エージェントが返す枠に関わらず、選択肢として常に並べる枠。
    static let commonWindows = ["5h", "7d"]

    private static let allWindows = ["claude": commonWindows, "codex": commonWindows]

    static let standard = DisplayPreferences(
        app: allWindows,
        menuBar: ["claude": ["5h"], "codex": ["7d"]],
        widget: allWindows
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
    }

    init(app: [String: [String]], menuBar: [String: [String]], widget: [String: [String]]) {
        self.app = app
        self.menuBar = menuBar
        self.widget = widget
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
