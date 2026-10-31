#!/usr/bin/env swift
//
//  make_icons.swift — 用 CoreGraphics 把 GHelper 科技感图标渲染成资源
//  产出：
//    Build/GHelper.iconset/        (多尺寸 PNG → iconutil 转 .icns)
//    Build/Menubar.pdf             (单色模板，菜单栏用)
//  设计：深青黑圆角方底 + 青绿风扇G + HUD 监控环（主图标）
//        六边形涡轮单色（菜单栏，isTemplate）

import Foundation
import CoreGraphics
import ImageIO

let BG       = CGColor(red: 14/255,  green: 27/255,  blue: 24/255,  alpha: 1)   // #0E1B18
let TEAL     = CGColor(red: 29/255,  green: 158/255, blue: 117/255, alpha: 1)   // #1D9E75
let TEAL_LT  = CGColor(red: 93/255,  green: 202/255, blue: 165/255, alpha: 1)   // #5DCAA5
let WHITE    = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

// 草图基于 180 逻辑单位，圆心 (90,90)
func renderAppIcon(size: Int, path: String) {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("cannot create context")
    }
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    let s = CGFloat(size) / 180.0
    ctx.scaleBy(x: s, y: s)

    // 圆角方底
    let bgRect = CGRect(x: 6, y: 6, width: 168, height: 168)
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: 40, cornerHeight: 40, transform: nil)
    ctx.addPath(bgPath)
    ctx.setFillColor(BG)
    ctx.fillPath()

    // HUD 监控环（带缺口，形似 G 的开口，朝右）
    ctx.addArc(center: CGPoint(x: 90, y: 90), radius: 76,
               startAngle: CGFloat(50 * Double.pi / 180),
               endAngle: CGFloat(360 * Double.pi / 180), clockwise: false)
    ctx.setStrokeColor(TEAL)
    ctx.setLineWidth(3)
    ctx.setLineCap(.round)
    ctx.strokePath()

    // 刻度（5 个）
    let ticks: [(CGPoint, CGPoint)] = [
        (CGPoint(x: 90, y: 14), CGPoint(x: 90, y: 24)),
        (CGPoint(x: 144, y: 36), CGPoint(x: 137, y: 43)),
        (CGPoint(x: 166, y: 90), CGPoint(x: 156, y: 90)),
        (CGPoint(x: 36, y: 36), CGPoint(x: 43, y: 43)),
        (CGPoint(x: 14, y: 90), CGPoint(x: 24, y: 90)),
    ]
    ctx.setStrokeColor(TEAL_LT)
    ctx.setLineWidth(3)
    ctx.setLineCap(.round)
    for (a, b) in ticks {
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.strokePath()
    }

    // 风扇叶片（拼成 G，三片 120° 旋转）
    ctx.translateBy(x: 90, y: 90)
    let blade = CGMutablePath()
    blade.move(to: CGPoint(x: 0, y: -16))
    blade.addLine(to: CGPoint(x: 30, y: -56))
    blade.addLine(to: CGPoint(x: 42, y: -40))
    blade.addLine(to: CGPoint(x: 14, y: -10))
    blade.closeSubpath()
    for deg in [0.0, 120.0, 240.0] {
        ctx.saveGState()
        ctx.rotate(by: deg * .pi / 180)
        ctx.addPath(blade)
        ctx.setFillColor(TEAL_LT)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // 中心核心
    ctx.addArc(center: CGPoint.zero, radius: 18, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.setFillColor(TEAL)
    ctx.fillPath()
    ctx.addArc(center: CGPoint.zero, radius: 7, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.setFillColor(BG)
    ctx.fillPath()

    guard let img = ctx.makeImage() else { fatalError("no image") }
    savePNG(img, to: path)
}

// 菜单栏：六边形涡轮单色（白色，透明底，作 template）
func renderMenubar(size: Int, path: String) {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("cannot create context")
    }
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    let s = CGFloat(size) / 72.0
    ctx.scaleBy(x: s, y: s)
    let c = CGPoint(x: 36, y: 36)
    let R: CGFloat = 32

    // 六边形外框（尖顶）
    let hex = CGMutablePath()
    for i in 0..<6 {
        let ang = (90.0 + Double(i) * 60.0) * .pi / 180.0
        let p = CGPoint(x: c.x + R * cos(ang), y: c.y - R * sin(ang))
        if i == 0 { hex.move(to: p) } else { hex.addLine(to: p) }
    }
    hex.closeSubpath()
    ctx.addPath(hex)
    ctx.setStrokeColor(WHITE)
    ctx.setLineWidth(4)
    ctx.strokePath()

    // 三片涡轮叶
    ctx.translateBy(x: c.x, y: c.y)
    let blade = CGMutablePath()
    blade.move(to: CGPoint(x: 0, y: -12))
    blade.addLine(to: CGPoint(x: 18, y: -26))
    blade.addLine(to: CGPoint(x: 24, y: -16))
    blade.addLine(to: CGPoint(x: 9, y: -6))
    blade.closeSubpath()
    for deg in [0.0, 120.0, 240.0] {
        ctx.saveGState()
        ctx.rotate(by: deg * .pi / 180)
        ctx.addPath(blade)
        ctx.setFillColor(WHITE)
        ctx.fillPath()
        ctx.restoreGState()
    }
    // 中心
    ctx.addArc(center: CGPoint.zero, radius: 9, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.setFillColor(WHITE)
    ctx.fillPath()

    guard let img = ctx.makeImage() else { fatalError("no image") }
    savePNG(img, to: path)
}

func savePNG(_ img: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, kUTTypePNG, 1, nil) else {
        fatalError("cannot create dest \(path)")
    }
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("finalize failed \(path)") }
}

// ---- 主图标 iconset ----
let iconset = "Build/GHelper.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
let sizes: [(Int, String)] = [
    (16,  "icon_16x16.png"),
    (32,  "icon_16x16@2x.png"),
    (32,  "icon_32x32.png"),
    (64,  "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024,"icon_512x512@2x.png"),
]
for (sz, name) in sizes {
    renderAppIcon(size: sz, path: "\(iconset)/\(name)")
}
print("✓ 主图标 iconset 已生成（\(sizes.count) 张）")

// ---- 菜单栏 PNG（白色单色）----
renderMenubar(size: 36, path: "Build/menubar@1x.png")
renderMenubar(size: 72, path: "Build/menubar@2x.png")
print("✓ 菜单栏图标 PNG 已生成")

// ---- 菜单栏 PDF（矢量模板，优先用）----
let pdfPath = "Build/Menubar.pdf"
var pdfBox = CGRect(x: 0, y: 0, width: 72, height: 72)
guard let pdfConsumer = CGDataConsumer(url: URL(fileURLWithPath: pdfPath) as CFURL),
      let pdfCtx = CGContext(consumer: pdfConsumer, mediaBox: &pdfBox, nil) else {
    fatalError("no pdf ctx")
}
pdfCtx.beginPDFPage(nil)
pdfCtx.scaleBy(x: 1, y: 1)
// 复用 renderMenubar 的绘制逻辑：在 pdfCtx 上再画一遍
let s2 = CGFloat(1)
_ = s2
pdfCtx.scaleBy(x: 1, y: 1)
let cc = CGPoint(x: 36, y: 36)
let RR: CGFloat = 32
let hex2 = CGMutablePath()
for i in 0..<6 {
    let ang = (90.0 + Double(i) * 60.0) * .pi / 180.0
    let p = CGPoint(x: cc.x + RR * cos(ang), y: cc.y - RR * sin(ang))
    if i == 0 { hex2.move(to: p) } else { hex2.addLine(to: p) }
}
hex2.closeSubpath()
pdfCtx.addPath(hex2)
pdfCtx.setStrokeColor(WHITE)
pdfCtx.setLineWidth(4)
pdfCtx.strokePath()
pdfCtx.translateBy(x: cc.x, y: cc.y)
let b2 = CGMutablePath()
b2.move(to: CGPoint(x: 0, y: -12))
b2.addLine(to: CGPoint(x: 18, y: -26))
b2.addLine(to: CGPoint(x: 24, y: -16))
b2.addLine(to: CGPoint(x: 9, y: -6))
b2.closeSubpath()
for deg in [0.0, 120.0, 240.0] {
    pdfCtx.saveGState()
    pdfCtx.rotate(by: deg * .pi / 180)
    pdfCtx.addPath(b2)
    pdfCtx.setFillColor(WHITE)
    pdfCtx.fillPath()
    pdfCtx.restoreGState()
}
pdfCtx.addArc(center: CGPoint.zero, radius: 9, startAngle: 0, endAngle: .pi * 2, clockwise: false)
pdfCtx.setFillColor(WHITE)
pdfCtx.fillPath()
pdfCtx.endPDFPage()
pdfCtx.closePDF()
print("✓ 菜单栏 Menubar.pdf 已生成")
