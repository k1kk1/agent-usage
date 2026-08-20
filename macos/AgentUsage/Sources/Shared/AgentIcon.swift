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

    /// 余白の量はアプリごとに違う（Claude は 48px 中 34px、ChatGPT は 36px 中 34px）。
    /// 画像をそのまま同じ寸法で描くと、余白の少ない方だけが大きく見えるので、
    /// 余白を取り除いた「絵の部分」を基準に揃える。
    private static let inkRatio: CGFloat = 0.92

    /// 読み込み結果（失敗も含む）をキャッシュして、再描画ごとのディスクアクセスを避ける。
    private static var cache: [String: Source?] = [:]
    private static let cacheLock = NSLock()

    /// 元画像と、その中で実際に絵が入っている範囲（単位座標）。
    private struct Source {
        let image: NSImage
        /// 0...1 の相対座標。左下原点。
        let ink: CGRect
    }

    static func officialImage(for agentID: String?, pointSize: CGFloat) -> NSImage? {
        guard let agentID, let source = source(for: agentID) else { return nil }

        let canvas = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: canvas)
        image.lockFocus()

        let size = source.image.size
        let from = NSRect(
            x: source.ink.minX * size.width,
            y: source.ink.minY * size.height,
            width: source.ink.width * size.width,
            height: source.ink.height * size.height
        )
        // 縦横比は保ったまま、長辺が inkRatio ぶんの大きさになるよう中央へ収める。
        let side = pointSize * inkRatio
        let scale = min(side / from.width, side / from.height)
        let drawn = NSSize(width: from.width * scale, height: from.height * scale)
        let to = NSRect(
            x: ((canvas.width - drawn.width) / 2).rounded(),
            y: ((canvas.height - drawn.height) / 2).rounded(),
            width: drawn.width,
            height: drawn.height
        )
        source.image.draw(in: to, from: from, operation: .sourceOver, fraction: 1)

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private static func source(for agentID: String) -> Source? {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if let cached = cache[agentID] { return cached }

        let loaded = officialPaths[agentID]
            .flatMap { FileManager.default.isReadableFile(atPath: $0) ? NSImage(contentsOfFile: $0) : nil }
            .map { Source(image: $0, ink: inkBounds(of: $0)) }
        cache[agentID] = loaded
        return loaded
    }

    /// 不透明なピクセルが入っている範囲を単位座標で返す。読めないときは全面。
    private static func inkBounds(of image: NSImage) -> CGRect {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard
            let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first
                ?? bitmap(from: image),
            rep.pixelsWide > 0, rep.pixelsHigh > 0
        else { return full }

        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return full }

        // colorAt は左上原点、描画は左下原点なので y を反転する。
        return CGRect(
            x: CGFloat(minX) / CGFloat(width),
            y: CGFloat(height - 1 - maxY) / CGFloat(height),
            width: CGFloat(maxX - minX + 1) / CGFloat(width),
            height: CGFloat(maxY - minY + 1) / CGFloat(height)
        )
    }

    private static func bitmap(from image: NSImage) -> NSBitmapImageRep? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg)
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
