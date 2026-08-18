// 把 iOS 的方形 AppIcon 加工成 macOS 风格图标(居中缩小 + 圆角遮罩 + 投影),
// 输出整套 iconset 尺寸,供 iconutil 打成 .icns。
// 用法: swift dmg/make-icns.swift   (由 build-dmg.sh 调用)

import AppKit

let srcPath = "shuhao/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
let outDir = "build/dmg/shuhao.iconset"

guard let src = NSImage(contentsOfFile: srcPath) else {
    fatalError("找不到源图标: \(srcPath)")
}

// macOS Big Sur 图标栅格:1024 画布,内容约 832,圆角约 186。
func renderCanvas(_ canvas: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let c = CGFloat(canvas)
    let content = c * 832.0 / 1024.0
    let inset = (c - content) / 2
    let radius = content * 186.0 / 832.0
    let rect = NSRect(x: inset, y: inset, width: content, height: content)

    // 小尺寸(<64)不画投影,免得糊成一团
    if canvas >= 64 {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.30)
        shadow.shadowOffset = NSSize(width: 0, height: -c * 0.008)
        shadow.shadowBlurRadius = c * 0.02
        shadow.set()
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        NSShadow().set()
    }

    NSGraphicsContext.current?.saveGraphicsState()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
    src.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.current?.restoreGraphicsState()

    // 安装包角标:右下角品牌渐变圆 + 白色向下箭头,和 app 本体图标区分开。
    // 小尺寸画不清楚,128 起才加。
    if canvas >= 128 {
        let d = c * 0.34                      // 角标直径
        let bx = rect.maxX - d * 0.55         // 圆心,压在圆角上但不出画布
        let by = rect.minY + d * 0.42
        let badgeRect = NSRect(x: bx - d / 2, y: by - d / 2, width: d, height: d)
        let circle = NSBezierPath(ovalIn: badgeRect)

        // 白描边让角标从任意底色上浮出来
        let ringWidth = d * 0.07
        NSColor.white.setFill()
        NSBezierPath(ovalIn: badgeRect.insetBy(dx: -ringWidth, dy: -ringWidth)).fill()

        // 品牌渐变(酒红 → 古铜金,同 DS.Palette)
        let gradient = NSGradient(
            starting: NSColor(red: 0.545, green: 0.141, blue: 0.251, alpha: 1),
            ending: NSColor(red: 0.757, green: 0.541, blue: 0.310, alpha: 1))!
        gradient.draw(in: circle, angle: -60)

        // 白色向下箭头
        let shaftW = d * 0.16
        let headHalf = d * 0.24
        let headH = d * 0.22
        let topY = by + d * 0.26
        let headTopY = by - d * 0.26 + headH
        let tipY = by - d * 0.26
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: bx - shaftW / 2, y: topY))
        arrow.line(to: NSPoint(x: bx + shaftW / 2, y: topY))
        arrow.line(to: NSPoint(x: bx + shaftW / 2, y: headTopY))
        arrow.line(to: NSPoint(x: bx + headHalf, y: headTopY))
        arrow.line(to: NSPoint(x: bx, y: tipY))
        arrow.line(to: NSPoint(x: bx - headHalf, y: headTopY))
        arrow.line(to: NSPoint(x: bx - shaftW / 2, y: headTopY))
        arrow.close()
        arrow.lineJoinStyle = .round
        NSColor.white.setFill()
        arrow.fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

try? FileManager.default.removeItem(atPath: outDir)
try! FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// iconset 命名规范:icon_<pt>x<pt>[@2x].png
let specs: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for spec in specs {
    let rep = renderCanvas(spec.px)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(spec.name).png"))
}
print("iconset written: \(outDir)")
