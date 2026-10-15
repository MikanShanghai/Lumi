// 生成 Lumi 的应用图标（.icns）。
// 用法：swift Scripts/make-icon.swift <输出目录>
// 设计与 App 内的品牌一致：蓝紫渐变圆角方 + 白色播放三角。
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dist"
let iconsetDir = "\(outDir)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

func makeIcon(size: Int) -> CGImage? {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let s = CGFloat(size)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // 圆角方（留出 macOS 图标惯例的边距）
    let inset = s * 0.085
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.235
    let rounded = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(rounded)
    ctx.clip()

    // 渐变：与 App 侧边栏 logo 一致（#0A84FF → #5E5CE6）
    let colors = [
        CGColor(red: 10 / 255, green: 132 / 255, blue: 255 / 255, alpha: 1),
        CGColor(red: 94 / 255, green: 92 / 255, blue: 230 / 255, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
    }

    // 左上角柔光，模拟材料受光
    if let glow = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawRadialGradient(
            glow,
            startCenter: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.maxY - rect.height * 0.22),
            startRadius: 0,
            endCenter: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.maxY - rect.height * 0.22),
            endRadius: rect.width * 0.85,
            options: []
        )
    }
    ctx.restoreGState()

    // 播放三角（略微右移做视觉居中）
    let triH = rect.height * 0.40
    let triW = triH * 0.86
    let centerX = rect.midX + triW * 0.06
    let centerY = rect.midY
    let tri = CGMutablePath()
    tri.move(to: CGPoint(x: centerX - triW / 2, y: centerY + triH / 2))
    tri.addLine(to: CGPoint(x: centerX - triW / 2, y: centerY - triH / 2))
    tri.addLine(to: CGPoint(x: centerX + triW / 2, y: centerY))
    tri.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.035,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
    ctx.addPath(tri)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    return ctx.makeImage()
}

func writePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let image = makeIcon(size: variant.size) else {
        print("绘制失败: \(variant.name)")
        exit(1)
    }
    writePNG(image, to: "\(iconsetDir)/\(variant.name).png")
}
print("iconset 已生成: \(iconsetDir)")
