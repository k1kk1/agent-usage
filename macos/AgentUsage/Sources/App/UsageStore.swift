import Foundation
import WidgetKit

/// daemon の state.json をイベント駆動で読み込み、ウィジェット用コピーを更新する。
/// ファイルI/OとJSON解析は専用キューに閉じ込め、UI反映だけをMainActorで行う。
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var state: UsageState?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var mirrorError: String?
    @Published private(set) var isSyncing = false

    let stateFileURL = UsageStateLoader.stateFileURL

    private let ioQueue = DispatchQueue(label: "dev.kikki.AgentUsage.state-reader", qos: .utility)
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var pendingSync: DispatchWorkItem?
    private var syncGeneration = 0
    private var lastMirroredData: Data?

    init() {
        configureWatcher()
        sync()
    }

    deinit {
        pendingSync?.cancel()
        fileSource?.cancel()
        directorySource?.cancel()
    }

    /// ローカルstate.jsonを再読込し、必要ならWidget更新も要求する。
    func forceSync() {
        sync(forceWidgetReload: true)
    }

    private func sync(forceWidgetReload: Bool = false) {
        syncGeneration += 1
        let generation = syncGeneration
        let sourceURL = stateFileURL
        isSyncing = true

        ioQueue.async { [weak self] in
            let outcome = Self.loadAndMirror(from: sourceURL)
            DispatchQueue.main.async {
                guard let self, self.syncGeneration == generation else { return }
                self.apply(outcome, forceWidgetReload: forceWidgetReload)
            }
        }
    }

    private func apply(_ outcome: SyncOutcome, forceWidgetReload: Bool) {
        defer {
            isSyncing = false
            lastSyncedAt = Date()
            configureWatcher()
        }

        switch outcome {
        case .success(let loaded, let data, let newMirrorError):
            state = loaded
            errorMessage = nil
            mirrorError = newMirrorError

            if forceWidgetReload || data != lastMirroredData {
                lastMirroredData = data
                WidgetCenter.shared.reloadTimelines(ofKind: "AgentUsageWidget")
            }

        case .failure(let message):
            // 一時的な読み込み失敗で、直前の値まで消さない。
            errorMessage = message
        }
    }

    /// state.jsonがある間はそのinodeを、まだ無い間は親ディレクトリを監視する。
    /// daemonはtmp→mvで置換するため、rename時はファイル監視を張り直す。
    private func configureWatcher() {
        if FileManager.default.fileExists(atPath: stateFileURL.path) {
            directorySource?.cancel()
            directorySource = nil
            startFileWatcher()
        } else {
            fileSource?.cancel()
            fileSource = nil
            startDirectoryWatcher()
        }
    }

    private func startFileWatcher() {
        guard fileSource == nil else { return }
        let fd = open(stateFileURL.path, O_EVTONLY)
        guard fd >= 0 else {
            startDirectoryWatcher()
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            if event.contains(.rename) || event.contains(.delete) {
                self.fileSource?.cancel()
                self.fileSource = nil
            }
            self.scheduleSync()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSource = source
    }

    private func startDirectoryWatcher() {
        guard directorySource == nil else { return }
        let directoryURL = stateFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let fd = open(directoryURL.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleSync()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        directorySource = source
    }

    private func scheduleSync() {
        pendingSync?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.sync()
        }
        pendingSync = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private enum SyncOutcome {
        case success(UsageState, Data, String?)
        case failure(String)
    }

    private nonisolated static func loadAndMirror(from sourceURL: URL) -> SyncOutcome {
        switch UsageStateLoader.load(from: sourceURL) {
        case .success(let loaded):
            guard let data = try? Data(contentsOf: sourceURL) else {
                return .failure(UsageStateLoader.LoadError.unreadable(sourceURL).localizedDescription)
            }
            return .success(loaded, data, mirror(data))
        case .failure(let error):
            return .failure(error.localizedDescription)
        }
    }

    private nonisolated static func mirror(_ data: Data) -> String? {
        let url = SharedPaths.hostMirrorURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return nil
        } catch {
            return "ウィジェットへ同期できません: \(error.localizedDescription)"
        }
    }
}
