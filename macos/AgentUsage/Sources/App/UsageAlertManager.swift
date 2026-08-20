import Combine
import Foundation
import UserNotifications

/// 使用率が80%・95%を上回った時だけ、一つの利用枠につき一度通知する。
@MainActor
final class UsageAlertManager: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if enabled {
                requestAuthorization()
            } else {
                levels.removeAll()
                UserDefaults.standard.removeObject(forKey: Self.levelsKey)
            }
        }
    }

    private static let enabledKey = "usageAlertsEnabled"
    private static let levelsKey = "usageAlertLevels"

    private var levels: [String: Int]
    private var observation: AnyCancellable?

    init(store: UsageStore) {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        levels = UserDefaults.standard.dictionary(forKey: Self.levelsKey) as? [String: Int] ?? [:]
        observation = store.$state.sink { [weak self] state in
            self?.evaluate(state: state)
        }
        if enabled { requestAuthorization() }
    }

    private func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func evaluate(state: UsageState?) {
        guard enabled, let state else { return }

        for agent in state.orderedAgents where agent.isOK {
            for window in agent.orderedWindows {
                guard let usedPct = window.usedPct else { continue }
                let level = usedPct >= 95 ? 95 : usedPct >= 80 ? 80 : 0
                let key = "\(agent.agent).\(window.label)"
                let previous = levels[key] ?? 0

                if level == 0 {
                    levels.removeValue(forKey: key)
                } else {
                    levels[key] = level
                    if level > previous {
                        sendNotification(agent: agent.label, window: window.label, usedPct: usedPct, level: level)
                    }
                }
            }
        }
        UserDefaults.standard.set(levels, forKey: Self.levelsKey)
    }

    private func sendNotification(agent: String, window: String, usedPct: Double, level: Int) {
        let content = UNMutableNotificationContent()
        content.title = "\(agent) \(window) が \(level)% に到達"
        content.body = "現在の使用率: \(UsageFormat.percent(usedPct))"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "usage-alert.\(agent).\(window).\(level)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
