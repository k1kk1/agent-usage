import ServiceManagement
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: UsageStore
    @EnvironmentObject private var alerts: UsageAlertManager
    var showsLaunchAtLogin = true

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @State private var showsReloadConfirmation = false
    @AppStorage(AppPreferences.compactStatusItemKey) private var compactStatusItem = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header

                if let state = store.state {
                    ForEach(state.orderedAgents, id: \.agent) { agent in
                        AgentSection(agent: agent)
                    }
                } else if let message = store.errorMessage {
                    UsageErrorView(message: message)
                        .frame(minHeight: 96)
                } else {
                    ProgressView("状態を読み込み中…")
                        .frame(maxWidth: .infinity, minHeight: 96, alignment: .center)
                }

                if let message = store.errorMessage, store.state != nil {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if showsLaunchAtLogin, let mirrorError = store.mirrorError {
                    Label(mirrorError, systemImage: "widget.small.badge.exclamationmark")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                if showsLaunchAtLogin {
                    Toggle("ログイン時に起動", isOn: $launchAtLogin)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        .onChange(of: launchAtLogin) { _, enabled in
                            setLaunchAtLogin(enabled)
                        }

                    Toggle("80%・95%で通知", isOn: $alerts.enabled)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))

                    Toggle("メニューバーを短く表示", isOn: $compactStatusItem)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        .help("エージェント別アイコンと使用率だけを表示します")

                    if let launchAtLoginError {
                        Text(launchAtLoginError)
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }
                }

                HStack {
                    Button(action: reload) {
                        Image(systemName: reloadSymbol)
                    }
                    .help("状態ファイルを再読み込み")
                    .accessibilityLabel("状態ファイルを再読み込み")

                    if showsReloadConfirmation {
                        Text("再読み込みました")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                    Button("終了") { NSApplication.shared.terminate(nil) }
                }
                .controlSize(.small)
            }
            .padding(14)
            .frame(minWidth: 330, maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Agent Usage")
                .font(.headline)
            Spacer()
            if let updatedAt = store.state?.updatedAt {
                VStack(alignment: .trailing, spacing: 1) {
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
