import Foundation

/// ウィジェット拡張は App Sandbox が必須（サンドボックス無しだと pluginkit に登録されない）。
/// そのためウィジェットから `~/.cache/agent-status/state.json` を直接読むことはできない。
///
/// App Group コンテナは Apple Developer Team ID とプロビジョニングプロファイルが要るため、
/// ローカル ad-hoc 署名では使えない。代わりにウィジェット自身のサンドボックスコンテナを
/// 受け渡し場所に使う:
///
///   ホストアプリ（非サンドボックス）が daemon の state.json を
///   ~/Library/Containers/<widget-id>/Data/Library/Application Support/AgentUsage/state.json
///   へミラーし、ウィジェットは自分の $HOME 相対でそれを読む。
enum SharedPaths {
    static let widgetBundleID = "dev.kikki.AgentUsage.Widget"
    static let mirrorFileName = "state.json"

    private static let containerRelativePath = "Library/Application Support/AgentUsage"

    /// ウィジェット側。サンドボックス下では NSHomeDirectory() が自身のコンテナ Data を指す。
    static var widgetMirrorURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(containerRelativePath)
            .appendingPathComponent(mirrorFileName)
    }

    /// ホストアプリ側。ウィジェットのコンテナを絶対パスで指す。
    static var hostMirrorURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers")
            .appendingPathComponent(widgetBundleID)
            .appendingPathComponent("Data")
            .appendingPathComponent(containerRelativePath)
            .appendingPathComponent(mirrorFileName)
    }
}
