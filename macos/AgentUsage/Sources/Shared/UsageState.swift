import Foundation

/// `agent-status-daemon.sh` が書き出す state.json のモデル。
/// 既定パスは `${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-status/state.json`。
struct UsageState: Decodable {
    let schemaVersion: Int?
    let updatedAt: String?
    let agents: [String: Agent]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case updatedAt = "updated_at"
        case agents
    }

    /// state.json に載る順で表示したいので、既知のエージェントを優先して並べる。
    var orderedAgents: [Agent] {
        let preferred = ["claude", "codex"]
        let known = preferred.compactMap { agents[$0] }
        let rest = agents
            .filter { !preferred.contains($0.key) }
            .values
            .sorted { $0.label < $1.label }
        return known + rest
    }

    struct Agent: Decodable {
        let agent: String
        let label: String
        let status: String
        let message: String?
        let updatedAt: String?
        let windows: [String: Window]
        let lastSuccessAt: String?
        let lastSuccessWindows: [String: Window]?
        let context: Context?
        let cost: Cost?

        enum CodingKeys: String, CodingKey {
            case agent, label, status, message, windows, context, cost
            case updatedAt = "updated_at"
            case lastSuccessAt = "last_success_at"
            case lastSuccessWindows = "last_success_windows"
        }

        var isOK: Bool { status == "ok" }

        /// primary / secondary を優先し、それ以外の枠も安定した順で並べる。
        /// Codex のように返す枠が変動するエージェントを取りこぼさないため。
        var orderedWindows: [Window] {
            ordered(windows)
        }

        var orderedLastSuccessWindows: [Window] {
            ordered(lastSuccessWindows ?? [:])
        }

        var hasStaleUsage: Bool {
            !isOK && !orderedLastSuccessWindows.isEmpty
        }

        private func ordered(_ source: [String: Window]) -> [Window] {
            let preferred = ["primary", "secondary"]
            let known = preferred.compactMap { source[$0] }
            let remaining = source
            .filter { !preferred.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map(\.value)
            return known + remaining
        }

        /// `offline` / `parse_error` などをそのまま出すと読みにくいので整形する。
        var statusText: String {
            if let message, !message.isEmpty { return message }
            switch status {
            case "offline": return "Offline"
            case "parse_error": return "Parse Error"
            case "error": return "Error"
            default: return status.capitalized
            }
        }
    }

    struct Window: Decodable {
        let label: String
        let usedPct: Double?
        let resetAt: String?

        enum CodingKeys: String, CodingKey {
            case label
            case usedPct = "used_pct"
            case resetAt = "reset_at"
        }
    }

    struct Context: Decodable {
        let remainingPct: Double?
        let usedPct: Double?

        enum CodingKeys: String, CodingKey {
            case remainingPct = "remaining_pct"
            case usedPct = "used_pct"
        }
    }

    struct Cost: Decodable {
        let totalUsd: Double?

        enum CodingKeys: String, CodingKey {
            case totalUsd = "total_usd"
        }
    }
}

enum UsageStateLoader {
    /// daemon 側と同じ既定パス解決。`AGENT_STATUS_STATE_FILE` などの環境変数も尊重する。
    static var stateFileURL: URL {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["AGENT_STATUS_STATE_FILE"], !explicit.isEmpty {
            return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
        }
        let dir: String
        if let stateDir = env["AGENT_STATUS_STATE_DIR"], !stateDir.isEmpty {
            dir = stateDir
        } else if let runtimeDir = env["XDG_RUNTIME_DIR"], !runtimeDir.isEmpty {
            dir = runtimeDir + "/agent-status"
        } else {
            dir = NSHomeDirectory() + "/.cache/agent-status"
        }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
            .appendingPathComponent("state.json")
    }

    enum LoadError: LocalizedError {
        case notFound(URL)
        case unreadable(URL)
        case invalidJSON(String)
        case mirrorMissing

        var errorDescription: String? {
            switch self {
            case .notFound(let url):
                return "state.json が見つかりません: \(url.path)"
            case .unreadable(let url):
                return "state.json を読めません: \(url.path)"
            case .invalidJSON(let detail):
                return "state.json を解釈できません: \(detail)"
            case .mirrorMissing:
                return "AgentUsage アプリを起動してください（state.json 未同期）"
            }
        }
    }

    static func load(from url: URL = stateFileURL) -> Result<UsageState, LoadError> {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(.notFound(url))
        }
        guard let data = try? Data(contentsOf: url) else {
            return .failure(.unreadable(url))
        }
        return decode(data)
    }

    /// ウィジェット用。ホストアプリが書いたミラーを読む。
    static func loadMirror() -> Result<UsageState, LoadError> {
        guard let data = try? Data(contentsOf: SharedPaths.widgetMirrorURL) else {
            return .failure(.mirrorMissing)
        }
        return decode(data)
    }

    private static func decode(_ data: Data) -> Result<UsageState, LoadError> {
        do {
            return .success(try JSONDecoder().decode(UsageState.self, from: data))
        } catch {
            return .failure(.invalidJSON(error.localizedDescription))
        }
    }
}
