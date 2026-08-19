import AppKit
import Combine
import SwiftUI

@main
@MainActor
struct AgentUsageApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

/// 通常アプリの本体ウィンドウを管理する。メニューバー表示はStatusItemControllerへ分離する。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private let displayPreferences = DisplayPreferencesStore()
    private lazy var alertManager = UsageAlertManager(store: store)
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainWindow()
        statusItemController = StatusItemController(
            store: store,
            display: displayPreferences,
            openSettings: { [weak self] in self?.showSettingsWindow() }
        )
        showMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func configureMainWindow() {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Agent Usage"
        let hosting = NSHostingController(
            rootView: ContentView(
                variant: .window,
                openSettings: { [weak self] in self?.showSettingsWindow() }
            )
            .environmentObject(store)
            .environmentObject(displayPreferences)
        )
        // 内容の高さちょうどに追従させる。固定サイズだと下に余白が残る。
        hosting.sizingOptions = [.preferredContentSize]
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.center()
        mainWindow = window
    }

    private func showSettingsWindow() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "設定"
            let hosting = NSHostingController(
                rootView: SettingsView()
                    .environmentObject(store)
                    .environmentObject(alertManager)
                    .environmentObject(displayPreferences)
            )
            hosting.sizingOptions = [.preferredContentSize]
            window.contentViewController = hosting
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showMainWindow() {
        guard let mainWindow else { return }
        mainWindow.deminiaturize(nil)
        mainWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// ステータス項目、ポップオーバー、表示文言を一元管理する。
@MainActor
private final class StatusItemController: NSObject, NSPopoverDelegate {
    private let store: UsageStore
    private let display: DisplayPreferencesStore
    private let openSettings: () -> Void
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var stateObservation: AnyCancellable?
    private var displayObservation: AnyCancellable?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?

    init(
        store: UsageStore,
        display: DisplayPreferencesStore,
        openSettings: @escaping () -> Void
    ) {
        self.store = store
        self.display = display
        self.openSettings = openSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusItem()
        configurePopover()
        stateObservation = store.$state.sink { [weak self] state in
            self?.updateStatusItem(state: state)
        }
        // 設定ウィンドウ側の変更もメニューバーへ反映する。
        displayObservation = display.$preferences.sink { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async { self.updateStatusItem(state: self.store.state) }
        }
        updateStatusItem(state: store.state)
    }

    deinit {
        stateObservation?.cancel()
        displayObservation?.cancel()
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Agent Usage"
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.delegate = self
        let hosting = NSHostingController(
            rootView: ContentView(
                variant: .popover,
                openSettings: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.openSettings()
                }
            )
            .environmentObject(store)
            .environmentObject(display)
        )
        // 固定サイズだと内容より縦に余る。SwiftUI 側の必要サイズへ追従させる。
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
    }

    /// メニューバーに並べる1エージェント分の表示内容。
    private struct StatusEntry {
        let agentID: String
        let label: String
        /// 右クリックメニューで選ばれている枠だけを、その順で持つ。
        let windows: [(label: String, usedPct: Double?)]
        /// 設定で選ばれているトークン項目。既定では空。
        let tokens: [(label: String, total: Int?)]

        var isEmpty: Bool { windows.isEmpty && tokens.isEmpty }

        var percentText: String {
            (windows.map { $0.usedPct.map(UsageFormat.percent) ?? "--%" }
                + tokens.map { UsageFormat.tokens($0.total) })
                .joined(separator: " / ")
        }

        var detailText: String {
            let detail = (windows
                .map { "\($0.label) \($0.usedPct.map(UsageFormat.percent) ?? "--%")" }
                + tokens.map { "\($0.label) \(UsageFormat.tokens($0.total))" })
                .joined(separator: " ")
            return "\(label) \(detail)"
        }
    }

    /// 右クリックメニューに並べる枠の候補。共通の 5h / 7d に、state.json 固有の枠を足す。
    private func menuWindowLabels(for agent: UsageState.Agent) -> [String] {
        let extras = agent.orderedWindows
            .map(\.label)
            .filter { !DisplayPreferences.commonWindows.contains($0) }
        return DisplayPreferences.commonWindows + extras
    }

    private func updateStatusItem(state: UsageState?) {
        let entries: [StatusEntry] = state?.orderedAgents.compactMap { agent in
            let available = menuWindowLabels(for: agent)
            let selected = display.windows(scope: .menuBar, agentID: agent.agent, available: available)

            let windows = selected.map { label -> (label: String, usedPct: Double?) in
                let window = agent.orderedWindows.first { $0.label == label }
                return (label, agent.isOK ? window?.usedPct : nil)
            }

            // トークンはローカルのログ由来なので、利用枠の取得が失敗していても出す。
            let tokens = display.metrics(scope: .menuBar, agentID: agent.agent)
                .map { metric -> (label: String, total: Int?) in
                    switch metric {
                    case .tokensToday: return (metric.rowLabel, agent.usage?.today?.total)
                    case .tokensSession: return (metric.rowLabel, agent.usage?.session?.total)
                    }
                }

            let entry = StatusEntry(
                agentID: agent.agent,
                label: agent.label,
                windows: windows,
                tokens: tokens
            )
            return entry.isEmpty ? nil : entry
        } ?? []

        // ツールチップと VoiceOver 向けにはエージェント名と枠名を残す。
        let fullTitle = entries.isEmpty
            ? "Agent Usage --%"
            : entries.map(\.detailText).joined(separator: "  ")

        statusItem.button?.title = ""
        statusItem.button?.image = statusBarImage(entries: entries)
        statusItem.button?.setAccessibilityLabel("Agent Usage: \(fullTitle)")
        statusItem.button?.toolTip = "Agent Usage\n\(fullTitle)"
    }

    /// アイコンと数値をまとめて1枚のテンプレート画像へ描画する。
    /// NSStatusBarButton の image/title 併用では1エージェントしか出せず、
    /// テンプレート画像ならライト/ダークのメニューバー色にも自動追従する。
    private func statusBarImage(entries: [StatusEntry]) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        let segments: [(icon: NSImage?, text: String)] = entries.isEmpty
            ? [(statusIcon(for: nil), "--%")]
            : entries.map { (statusIcon(for: $0.agentID), $0.percentText) }

        let iconGap: CGFloat = 3
        let segmentGap: CGFloat = 8
        var width: CGFloat = 0
        var measured: [(icon: NSImage?, text: NSString, textSize: NSSize)] = []
        for (index, segment) in segments.enumerated() {
            let text = segment.text as NSString
            let textSize = text.size(withAttributes: textAttributes)
            if index > 0 { width += segmentGap }
            if let icon = segment.icon { width += icon.size.width + iconGap }
            width += textSize.width
            measured.append((segment.icon, text, textSize))
        }

        let height = NSStatusBar.system.thickness - 6
        let image = NSImage(size: NSSize(width: max(width.rounded(.up), 1), height: height))
        image.lockFocus()
        var x: CGFloat = 0
        for (index, segment) in measured.enumerated() {
            if index > 0 { x += segmentGap }
            if let icon = segment.icon {
                let rect = NSRect(
                    x: x,
                    y: ((height - icon.size.height) / 2).rounded(),
                    width: icon.size.width,
                    height: icon.size.height
                )
                icon.draw(in: rect)
                x += icon.size.width + iconGap
            }
            segment.text.draw(
                at: NSPoint(x: x, y: ((height - segment.textSize.height) / 2).rounded()),
                withAttributes: textAttributes
            )
            x += segment.textSize.width
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    /// 左クリックはポップオーバー、右クリック（と control+クリック）はメニュー。
    @objc private func handleClick() {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isSecondary {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func showContextMenu() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        contextMenu().popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.minY - 4),
            in: button
        )
    }

    /// 表示する枠のチェックボックスと終了を出す。
    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for agent in store.state?.orderedAgents ?? [] {
            let header = NSMenuItem(title: agent.label, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            let available = menuWindowLabels(for: agent)
            for label in available {
                let item = NSMenuItem(
                    title: label,
                    action: #selector(toggleStatusWindow(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.indentationLevel = 1
                item.representedObject = [agent.agent, label] + available
                item.state = display.isSelected(
                    scope: .menuBar,
                    agentID: agent.agent,
                    window: label
                ) ? .on : .off
                menu.addItem(item)
            }
            for metric in DisplayPreferences.Metric.allCases {
                let item = NSMenuItem(
                    title: metric.title,
                    action: #selector(toggleStatusMetric(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.indentationLevel = 1
                item.representedObject = [agent.agent, metric.rawValue]
                item.state = display.isSelected(
                    scope: .menuBar,
                    agentID: agent.agent,
                    metric: metric
                ) ? .on : .off
                menu.addItem(item)
            }

            menu.addItem(.separator())
        }

        let settings = NSMenuItem(title: "設定…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    @objc private func showSettings() {
        openSettings()
    }

    @objc private func toggleStatusWindow(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String], payload.count >= 2 else { return }
        display.toggle(
            scope: .menuBar,
            agentID: payload[0],
            window: payload[1],
            available: Array(payload.dropFirst(2))
        )
        updateStatusItem(state: store.state)
    }

    @objc private func toggleStatusMetric(_ sender: NSMenuItem) {
        guard
            let payload = sender.representedObject as? [String], payload.count >= 2,
            let metric = DisplayPreferences.Metric(rawValue: payload[1])
        else { return }
        display.toggle(scope: .menuBar, agentID: payload[0], metric: metric)
        updateStatusItem(state: store.state)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        startOutsideClickMonitoring()
        // macOSのメニューバー構成によって下に離れることがあるため、実座標で補正する。
        DispatchQueue.main.async { [weak self, weak button] in
            guard let self, let button else { return }
            self.alignPopoverBelowStatusItem(button: button)
        }
    }

    private func alignPopoverBelowStatusItem(button: NSStatusBarButton) {
        guard
            let statusWindow = button.window,
            let popoverWindow = popover.contentViewController?.view.window
        else { return }

        let statusRect = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visibleFrame = statusWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        var origin = popoverWindow.frame.origin
        origin.y = statusRect.minY - popoverWindow.frame.height

        if let visibleFrame {
            origin.x = min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - popoverWindow.frame.width)
            origin.y = max(origin.y, visibleFrame.minY)
        }
        popoverWindow.setFrameOrigin(origin)
    }

    private func statusIcon(for agentID: String?) -> NSImage? {
        // 公式アプリのトレイ用アイコンが読めればそれを優先する。
        if let official = AgentIcon.officialImage(for: agentID, pointSize: 12) {
            return official
        }

        let symbolName = AgentSymbol.name(for: agentID)
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: agentID ?? "Agent Usage")?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }

    private func startOutsideClickMonitoring() {
        stopOutsideClickMonitoring()

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            let popoverWindow = self.popover.contentViewController?.view.window
            let statusWindow = self.statusItem.button?.window
            if event.window !== popoverWindow, event.window !== statusWindow {
                self.popover.performClose(nil)
            }
            return event
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.popover.performClose(nil)
            }
        }
    }

    private func stopOutsideClickMonitoring() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        stopOutsideClickMonitoring()
    }
}
