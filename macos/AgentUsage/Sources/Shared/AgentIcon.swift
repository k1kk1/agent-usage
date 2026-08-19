import AppKit
import SwiftUI

/// 公式アプリが同梱するメニューバー用テンプレート画像をそのまま借りる。
/// リポジトリに他社ロゴを持ち込まないため、ビルド時ではなく実行時に読む。
/// 見つからない環境（未インストール、ウィジェットのサンドボックス下など）では
/// `AgentSymbol` の SF Symbols にフォールバックする。
enum AgentIcon {
    private static let officialPaths: [String: String] = [
        "claude": "/Applications/Claude.app/Contents/Resources/TrayIconTemplate@2x.png",
        "codex": "/Applications/ChatGPT.app/Contents/Resources/chatgptTemplate@2x.png"
    ]

    /// 読み込み結果（失敗も含む）をキャッシュして、再描画ごとのディスクアクセスを避ける。
    private static var cache: [String: NSImage?] = [:]
    private static let cacheLock = NSLock()

    static func officialImage(for agentID: String?, pointSize: CGFloat) -> NSImage? {
        guard let agentID, let path = officialPaths[agentID] else { return nil }

        cacheLock.lock()
        let source: NSImage?
        if let cached = cache[agentID] {
            source = cached
        } else {
            source = FileManager.default.isReadableFile(atPath: path)
                ? NSImage(contentsOfFile: path)
                : nil
            cache[agentID] = source
        }
        cacheLock.unlock()

        guard let image = source?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: pointSize, height: pointSize)
        image.isTemplate = true
        return image
    }
}

/// 一覧の見出し用アイコン。公式アイコンがあればそれを、無ければ SF Symbols を出す。
struct AgentIconView: View {
    let agentID: String
    var size: CGFloat = 11

    var body: some View {
        if let image = AgentIcon.officialImage(for: agentID, pointSize: size) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: AgentSymbol.name(for: agentID))
                .font(.system(size: size - 1, weight: .medium))
        }
    }
}
