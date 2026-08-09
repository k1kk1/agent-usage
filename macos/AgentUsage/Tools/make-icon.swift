#!/usr/bin/env swift
// AppIcon.appiconset を生成する。
//
//   swift Tools/make-icon.swift Sources/App/Assets.xcassets/AppIcon.appiconset
//
// デザインは利用率ゲージ。下部が開いた 240 度のリングで、
// 目盛りに沿って緑 → 橙 → 赤（pane 版と同じしきい値の並び）へ変化する。

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - パラメータ

/// リングをどこまで塗るか。アイコンとして映える程度に留める。
let gaugeFraction = 0.68
/// リング下部の開口。y 軸が上向きの座標系での角度。
let trackStartDegrees = 210.0
let trackSweepDegrees = 240.0

struct RGB {
    let r, g, b: Double

    func blend(to other: RGB, _ t: Double) -> RGB {
        RGB(
            r: r + (other.r - r) * t,
            g: g + (other.g - g) * t,
            b: b + (other.b - b) * t
        )
    }

    var cgColor: CGColor {
        CGColor(red: r, green: g, blue: b, alpha: 1)
    }
}

let backgroundTop = RGB(r: 0.19, g: 0.22, b: 0.28)
let backgroundBottom = RGB(r: 0.08, g: 0.10, b: 0.14)
let trackColor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.12)

let gaugeLow = RGB(r: 0.30, g: 0.85, b: 0.42)
let gaugeMid = RGB(r: 1.00, g: 0.69, b: 0.13)
let gaugeHigh = RGB(r: 1.00, g: 0.36, b: 0.36)

/// 目盛り位置 t (0...1) に対応する色。50% で橙、80% で赤に寄せる。
func gaugeColor(at t: Double) -> RGB {
    if t <= 0.5 {
        return gaugeLow.blend(to: gaugeMid, t / 0.5)
    }
    return gaugeMid.blend(to: gaugeHigh, min((t - 0.5) / 0.3, 1))
}

// MARK: - 描画

func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }

/// Big Sur 以降の macOS アイコンは 1024 のキャンバスに対して本体が約 824。
func squirclePath(in rect: CGRect) -> CGPath {
    CGPath(
        roundedRect: rect,
        cornerWidth: rect.width * 0.2237,
        cornerHeight: rect.height * 0.2237,
        transform: nil
    )
}

func drawIcon(size: Int) -> CGImage? {
    let s = Double(size)
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    let inset = s * 0.098
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)

    // 背景の角丸 + 縦グラデーション
    ctx.saveGState()
    ctx.addPath(squirclePath(in: body))
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [backgroundTop.cgColor, backgroundBottom.cgColor] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: body.maxY),
        end: CGPoint(x: 0, y: body.minY),
        options: []
    )
    ctx.restoreGState()

    let center = CGPoint(x: s / 2, y: s / 2)
    let radius = s * 0.283
    let lineWidth = s * 0.115

    ctx.setLineCap(.round)
    ctx.setLineWidth(lineWidth)

    // トラック（未使用部分）
    ctx.setStrokeColor(trackColor)
    ctx.addArc(
        center: center,
        radius: radius,
        startAngle: radians(trackStartDegrees),
        endAngle: radians(trackStartDegrees - trackSweepDegrees),
        clockwise: true
    )
    ctx.strokePath()

    // ゲージ。色が連続的に変わるので細かい弧に分割して描く。
    let segments = 180
    let filled = Int(Double(segments) * gaugeFraction)
    for i in 0..<filled {
        let t0 = Double(i) / Double(segments)
        let t1 = Double(i + 1) / Double(segments)
        // 継ぎ目が見えないよう少しだけ重ねる。
        let overlap = 0.6 / Double(segments)
        ctx.setStrokeColor(gaugeColor(at: t0).cgColor)
        ctx.addArc(
            center: center,
            radius: radius,
            startAngle: radians(trackStartDegrees - t0 * trackSweepDegrees),
            endAngle: radians(trackStartDegrees - (t1 + overlap) * trackSweepDegrees),
            clockwise: true
        )
        ctx.strokePath()
    }

    // 中央のドット。小サイズでもゲージだと分かるようにする。
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
    let dot = s * 0.052
    ctx.fillEllipse(in: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2))

    return ctx.makeImage()
}

func write(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw NSError(domain: "make-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot create \(url.path)"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "make-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot write \(url.path)"])
    }
}

// MARK: - appiconset の出力

struct Slot {
    let point: Int
    let scale: Int
    var pixels: Int { point * scale }
    var fileName: String { "icon_\(point)x\(point)\(scale == 2 ? "@2x" : "").png" }
}

let slots = [16, 32, 128, 256, 512].flatMap { point in
    [Slot(point: point, scale: 1), Slot(point: point, scale: 2)]
}

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Sources/App/Assets.xcassets/AppIcon.appiconset"
let outputURL = URL(fileURLWithPath: outputPath)

try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

// 同じピクセルサイズを重複生成しないようキャッシュする。
var rendered: [Int: CGImage] = [:]
for slot in slots {
    let image: CGImage
    if let cached = rendered[slot.pixels] {
        image = cached
    } else {
        guard let made = drawIcon(size: slot.pixels) else {
            FileHandle.standardError.write("failed to render \(slot.pixels)px\n".data(using: .utf8)!)
            exit(1)
        }
        rendered[slot.pixels] = made
        image = made
    }
    try write(image, to: outputURL.appendingPathComponent(slot.fileName))
}

let images = slots.map { slot in
    """
        {
          "size" : "\(slot.point)x\(slot.point)",
          "idiom" : "mac",
          "filename" : "\(slot.fileName)",
          "scale" : "\(slot.scale)x"
        }
    """
}

let contents = """
{
  "images" : [
\(images.joined(separator: ",\n"))
  ],
  "info" : {
    "version" : 1,
    "author" : "xcode"
  }
}

"""

try contents.write(
    to: outputURL.appendingPathComponent("Contents.json"),
    atomically: true,
    encoding: .utf8
)

print("wrote \(slots.count) icons to \(outputURL.path)")
