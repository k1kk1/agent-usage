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
    private lazy var alertManager = UsageAlertManager(store: store)
    private var mainWindow: NSWindow?
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPreferences.registerDefaults()
        configureMainWindow()
        statusItemController = StatusItemController(store: store, alerts: alertManager)
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
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Agent Usage"
        window.minSize = NSSize(width: 360, height: 280)
        window.contentView = NSHostingView(
            rootView: ContentView()
                .environmentObject(store)
                .environmentObject(alertManager)
        )
        window.isReleasedWhenClosed = false
        window.center()
        mainWindow = window
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
    private let alerts: UsageAlertManager
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var stateObservation: AnyCancellable?
    private var preferencesObservation: AnyCancellable?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?

    init(store: UsageStore, alerts: UsageAlertManager) {
        self.store = store
        self.alerts = alerts
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusItem()
        configurePopover()
        stateObservation = store.$state.sink { [weak self] state in
            self?.updateStatusItem(state: state)
        }
        preferencesObservation = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateStatusItem(state: self.store.state)
            }
        updateStatusItem(state: store.state)
    }

    deinit {
        stateObservation?.cancel()
        preferencesObservation?.cancel()
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
        button.image = NSImage(
            systemSymbolName: "gauge.with.dots.needle.33percent",
            accessibilityDescription: "Agent Usage"
        )
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        button.target = self
        button.action = #selector(togglePopover)
        button.toolTip = "Agent Usage"
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 340, height: 350)
        popover.contentViewController = NSHostingController(
            rootView: ContentView(showsLaunchAtLogin: false)
                .environmentObject(store)
                .environmentObject(alerts)
        )
    }

    private func updateStatusItem(state: UsageState?) {
        let mostUrgent = state?.orderedAgents
            .filter(\.isOK)
            .flatMap { agent in
                agent.orderedWindows.compactMap { window in
                    window.usedPct.map {
                        (agentID: agent.agent, agentLabel: agent.label, usedPct: $0)
                    }
                }
            }
            .max { $0.usedPct < $1.usedPct }

        let fullTitle = mostUrgent.map {
            "\($0.agentLabel) \(UsageFormat.percent($0.usedPct))"
        } ?? "Agent Usage --%"
        let compactTitle = mostUrgent.map {
            UsageFormat.percent($0.usedPct)
        } ?? "--%"
        let title = UserDefaults.standard.bool(forKey: AppPreferences.compactStatusItemKey)
            ? compactTitle
            : fullTitle
        statusItem.button?.image = statusIcon(for: mostUrgent?.agentID)
        statusItem.button?.title = title
        statusItem.button?.setAccessibilityLabel("Agent Usage: \(fullTitle)")
        statusItem.button?.toolTip = "Agent Usage\n\(fullTitle)"
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
        let symbolName: String
        let description: String
        switch agentID {
        case "claude":
            symbolName = "sparkles"
            description = "Claude Code"
        case "codex":
            symbolName = "chevron.left.forwardslash.chevron.right"
            description = "Codex"
        default:
            symbolName = "gauge.with.dots.needle.33percent"
            description = "Agent Usage"
        }

        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)?
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
