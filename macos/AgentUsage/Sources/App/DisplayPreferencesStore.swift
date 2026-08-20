import Foundation
import WidgetKit

/// 表示する枠の選択を UserDefaults に保存し、ウィジェット用のミラーも書き出す。
@MainActor
final class DisplayPreferencesStore: ObservableObject {
    @Published private(set) var preferences: DisplayPreferences

    private static let key = "displayPreferences"

    init() {
        if
            let data = UserDefaults.standard.data(forKey: Self.key),
            let decoded = try? JSONDecoder().decode(DisplayPreferences.self, from: data)
        {
            preferences = decoded
        } else {
            preferences = .standard
        }
        // ウィジェットが既定値のまま取り残されないよう、起動時にも書き出す。
        mirror()
    }

    func windows(scope: DisplayPreferences.Scope, agentID: String, available: [String]) -> [String] {
        preferences.windows(scope: scope, agentID: agentID, available: available)
    }

    func isSelected(scope: DisplayPreferences.Scope, agentID: String, window: String) -> Bool {
        preferences.isSelected(scope: scope, agentID: agentID, window: window)
    }

    func toggle(
        scope: DisplayPreferences.Scope,
        agentID: String,
        window: String,
        available: [String]
    ) {
        preferences.toggle(scope: scope, agentID: agentID, window: window, available: available)
        save()
    }

    func metrics(scope: DisplayPreferences.Scope, agentID: String) -> [DisplayPreferences.Metric] {
        preferences.metrics(scope: scope, agentID: agentID)
    }

    func isSelected(
        scope: DisplayPreferences.Scope,
        agentID: String,
        metric: DisplayPreferences.Metric
    ) -> Bool {
        preferences.isSelected(scope: scope, agentID: agentID, metric: metric)
    }

    func toggle(
        scope: DisplayPreferences.Scope,
        agentID: String,
        metric: DisplayPreferences.Metric
    ) {
        preferences.toggle(scope: scope, agentID: agentID, metric: metric)
        save()
    }

    func plan(agentID: String) -> DisplayPreferences.TokenPlan {
        preferences.plan(agentID: agentID)
    }

    func setPlan(_ plan: DisplayPreferences.TokenPlan, agentID: String) {
        guard preferences.plan(agentID: agentID) != plan else { return }
        preferences.setPlan(plan, agentID: agentID)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(preferences) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
        mirror()
        WidgetCenter.shared.reloadTimelines(ofKind: "AgentUsageWidget")
    }

    private func mirror() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        let url = SharedPaths.hostPreferencesURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
