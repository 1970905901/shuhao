// DMG 安装窗口背景图生成脚本。
// 用法: swift dmg/make-background.swift
// 输出: dmg/dmg-background.png (600x400pt @2x, 144dpi —— Finder 按 600x400 显示,Retina 清晰)
//
// 装 DMG 时的图标摆位建议(与本图布局对齐,窗口 600x400):
//   随便听.app    → (150, 205)
//   Applications → (450, 205)

import AppKit

let widthPt: CGFloat = 600
let heightPt: CGFloat = 400
let scale: CGFloat = 2

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(widthPt * scale), pixelsHigh: Int(heightPt * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("bitmap rep failed") }
rep.size = NSSize(width: widthPt, height: heightPt)   // 2x 像素 + 点尺寸 = 144dpi

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// ---- 背景:纯白
NSColor.white.setFill()
NSRect(x: 0, y: 0, width: widthPt, height: heightPt).fill()

// ---- 文本工具(坐标系原点在左下,topY 按"距顶部"理解)
func drawCentered(_ text: String, font: NSFont, color: NSColor, topY: CGFloat) {
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: color, .paragraphStyle: para,
    ]
    let str = NSAttributedString(string: text, attributes: attrs)
    let size = str.size()
    str.draw(in: NSRect(x: 0, y: heightPt - topY - size.height,
                        width: widthPt, height: size.height))
}

let pingfangSemibold = NSFont(name: "PingFangSC-Semibold", size: 34)
    ?? NSFont.systemFont(ofSize: 34, weight: .semibold)
let pingfangRegular15 = NSFont(name: "PingFangSC-Regular", size: 15)
    ?? NSFont.systemFont(ofSize: 15)
let pingfangRegular13 = NSFont(name: "PingFangSC-Regular", size: 13)
    ?? NSFont.systemFont(ofSize: 13)

// ---- 标题 + slogan
drawCentered("随便听", font: pingfangSemibold,
             color: NSColor(white: 0.13, alpha: 1), topY: 52)
drawCentered("好音乐，随便听", font: pingfangRegular15,
             color: NSColor(white: 0.42, alpha: 1), topY: 102)

// ---- 中间引导箭头(与图标行同高,icons 在 y=205)
let arrowCenter = NSPoint(x: widthPt / 2, y: heightPt - 205)
let tailHalf: CGFloat = 7      // 箭杆半高
let headHalf: CGFloat = 17     // 箭头半高
let tailLeft = arrowCenter.x - 38
let headStart = arrowCenter.x + 10
let tip = arrowCenter.x + 38

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: tailLeft, y: arrowCenter.y + tailHalf))
arrow.line(to: NSPoint(x: headStart, y: arrowCenter.y + tailHalf))
arrow.line(to: NSPoint(x: headStart, y: arrowCenter.y + headHalf))
arrow.line(to: NSPoint(x: tip, y: arrowCenter.y))
arrow.line(to: NSPoint(x: headStart, y: arrowCenter.y - headHalf))
arrow.line(to: NSPoint(x: headStart, y: arrowCenter.y - tailHalf))
arrow.line(to: NSPoint(x: tailLeft, y: arrowCenter.y - tailHalf))
arrow.close()
arrow.lineJoinStyle = .round
arrow.lineWidth = 2

NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor(white: 0, alpha: 0.10)
shadow.shadowOffset = NSSize(width: 0, height: -1.5)
shadow.shadowBlurRadius = 3
shadow.set()
NSColor.white.setFill()
arrow.fill()
NSGraphicsContext.current?.restoreGraphicsState()
NSColor(white: 0.78, alpha: 1).setStroke()
arrow.stroke()

// ---- 底部安装说明
drawCentered("拖动 随便听 到右侧的 Applications 文件夹即可完成安装",
             font: pingfangRegular13, color: NSColor(white: 0.42, alpha: 1), topY: 332)
drawCentered("运行后可在菜单栏快速控制播放",
             font: pingfangRegular13, color: NSColor(white: 0.42, alpha: 1), topY: 354)

NSGraphicsContext.restoreGraphicsState()

// ---- 输出 PNG
guard let data = rep.representation(using: .png, properties: [:]) else {
    fatalError("png encode failed")
}
let out = URL(fileURLWithPath: "dmg/dmg-background.png")
try! data.write(to: out)
print("written: \(out.path) (\(rep.pixelsWide)x\(rep.pixelsHigh)px @ \(Int(widthPt))x\(Int(heightPt))pt)")
