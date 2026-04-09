#!/usr/bin/env swift
// Trio app iconを動的生成 (CoreGraphics)
// 1024x1024 のアプリアイコン + メニューバー用テンプレート (22pt)
import AppKit
import CoreGraphics

func drawAppIcon(size: CGFloat) -> CGImage? {
    let ctx = CGContext(
        data: nil,
        width: Int(size), height: Int(size),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    // 背景: 丸角+グラデーション (Dark teal → black)
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius: CGFloat = size * 0.22  // macOS 11+ icon curvature
    let bgPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()

    let grad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.06, green: 0.10, blue: 0.18, alpha: 1),  // #0F1A2E 深紺
            CGColor(red: 0.13, green: 0.22, blue: 0.36, alpha: 1),  // #21385C
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])
    ctx.restoreGState()

    // 3枚のカードを斜めに重ねる (上から順に)
    let cardW = size * 0.56
    let cardH = size * 0.14
    let cardCornerR = cardH * 0.3
    let cardX = (size - cardW) / 2
    let spacing = cardH * 1.35
    let startY = size * 0.58

    // 各カードの色 (Slack紫 / LINE緑 / オレンジ)
    let colors: [(CGColor, CGFloat)] = [
        (CGColor(red: 0.29, green: 0.08, blue: 0.30, alpha: 1), 0.96),   // Slack #4A154B
        (CGColor(red: 0.02, green: 0.78, blue: 0.33, alpha: 1), 0.98),   // LINE #06C755
        (CGColor(red: 0.94, green: 0.40, blue: 0.00, alpha: 1), 1.00),   // CW #F06400
    ]

    for (i, (color, alpha)) in colors.enumerated() {
        let offset = CGFloat(i) * spacing
        let offsetX = CGFloat(i - 1) * size * 0.02  // わずかにずらす
        let r = CGRect(x: cardX + offsetX, y: startY - offset, width: cardW, height: cardH)
        let path = CGPath(roundedRect: r, cornerWidth: cardCornerR, cornerHeight: cardCornerR, transform: nil)

        // ドロップシャドウ
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.01),
                      blur: size * 0.025,
                      color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(path)
        ctx.setFillColor(color.copy(alpha: alpha)!)
        ctx.fillPath()
        ctx.restoreGState()

        // カード内の「テキスト行」風の細線
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setFillColor(CGColor(gray: 1.0, alpha: 0.85))
        let lineH = cardH * 0.12
        let lineMargin = cardH * 0.28
        // 上の行 (送信者名)
        ctx.fill(CGRect(
            x: r.minX + cardH * 0.4, y: r.minY + cardH * 0.60,
            width: cardW * 0.35, height: lineH
        ))
        // 下の行 (本文プレビュー)
        ctx.setFillColor(CGColor(gray: 1.0, alpha: 0.55))
        ctx.fill(CGRect(
            x: r.minX + cardH * 0.4, y: r.minY + lineMargin + cardH * 0.05,
            width: cardW * 0.55, height: lineH * 0.85
        ))
        ctx.restoreGState()

        // 左のアバター円
        ctx.saveGState()
        ctx.setFillColor(CGColor(gray: 1.0, alpha: 0.4))
        ctx.fillEllipse(in: CGRect(
            x: r.minX + cardH * 0.12,
            y: r.minY + cardH * 0.22,
            width: cardH * 0.56,
            height: cardH * 0.56
        ))
        ctx.restoreGState()
    }

    return ctx.makeImage()
}

/// メニューバー用テンプレートアイコン (黒1色、22x22)
/// トレイ + 3つの書類が覗く形
func drawMenuIcon(size: CGFloat) -> CGImage? {
    let ctx = CGContext(
        data: nil,
        width: Int(size), height: Int(size),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    ctx.setFillColor(CGColor(gray: 0, alpha: 0))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

    let black = CGColor(gray: 0, alpha: 1)
    ctx.setFillColor(black)

    // 3本の横線 (=3件のカードを表す)
    let lineH = size * 0.12
    let lineW = size * 0.70
    let lineX = (size - lineW) / 2
    let startY = size * 0.68
    let gap = size * 0.22

    for i in 0..<3 {
        let y = startY - CGFloat(i) * gap
        // 左の丸(アバター)
        let dotR = lineH * 1.4
        ctx.fillEllipse(in: CGRect(x: lineX, y: y - dotR*0.2, width: dotR, height: dotR))
        // 右の線(本文)
        let rectPath = CGPath(
            roundedRect: CGRect(x: lineX + dotR + size*0.06, y: y + lineH*0.2,
                                 width: lineW - dotR - size*0.06, height: lineH),
            cornerWidth: lineH/2, cornerHeight: lineH/2, transform: nil
        )
        ctx.addPath(rectPath)
        ctx.fillPath()
    }

    return ctx.makeImage()
}

func savePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("✅ \(path)")
}

// Iconset生成 (macOS要件: 16,32,64,128,256,512,1024 + @2x)
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

let iconset = "/tmp/Trio.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

for (size, name) in sizes {
    if let img = drawAppIcon(size: CGFloat(size)) {
        savePNG(img, to: "\(iconset)/\(name)")
    }
}

// メニューバー用テンプレート (黒1色, 22x22 と @2x 44x44)
for (size, name) in [(22, "TrioTemplate.png"), (44, "TrioTemplate@2x.png")] {
    if let img = drawMenuIcon(size: CGFloat(size)) {
        savePNG(img, to: "/tmp/\(name)")
    }
}

// 1024プレビュー
if let img = drawAppIcon(size: 1024) {
    savePNG(img, to: "/tmp/trio_icon_preview.png")
}

print("\n次: iconutil -c icns \(iconset) -o Trio.icns")
