#!/usr/bin/env swift
// 生成菜单栏图标在深色/浅色状态栏下的模拟预览，用于确认显示效果
import Foundation
import CoreGraphics
import ImageIO

let WHITE = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
let BLACK = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

func drawMenubar(ctx: CGContext, cx: CGFloat, color: CGColor) {
    ctx.saveGState()
    ctx.translateBy(x: cx, y: 70)
    let R: CGFloat = 30
    let hex = CGMutablePath()
    for i in 0..<6 {
        let ang = (90.0 + Double(i) * 60.0) * .pi / 180.0
        let p = CGPoint(x: R * cos(ang), y: -R * sin(ang))
        if i == 0 { hex.move(to: p) } else { hex.addLine(to: p) }
    }
    hex.closeSubpath()
    ctx.addPath(hex)
    ctx.setStrokeColor(color)
    ctx.setLineWidth(4)
    ctx.strokePath()
    let blade = CGMutablePath()
    blade.move(to: CGPoint(x: 0, y: -11))
    blade.addLine(to: CGPoint(x: 17, y: -24))
    blade.addLine(to: CGPoint(x: 22, y: -15))
    blade.addLine(to: CGPoint(x: 8, y: -5))
    blade.closeSubpath()
    for deg in [0.0, 120.0, 240.0] {
        ctx.saveGState()
        ctx.rotate(by: deg * .pi / 180)
        ctx.addPath(blade)
        ctx.setFillColor(color)
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.addArc(center: .zero, radius: 8, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.setFillColor(color)
    ctx.fillPath()
    ctx.restoreGState()
}

let W = 680, H = 140
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError() }
ctx.clear(CGRect(x: 0, y: 0, width: W, height: H))
ctx.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: W / 2, height: H))
ctx.setFillColor(CGColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1))
ctx.fill(CGRect(x: W / 2, y: 0, width: W / 2, height: H))
// 左侧深栏：白图标；右侧浅栏：黑图标（模拟 isTemplate 自动着色）
drawMenubar(ctx: ctx, cx: 70, color: WHITE)
drawMenubar(ctx: ctx, cx: 70 + CGFloat(W) / 2, color: BLACK)
guard let img = ctx.makeImage() else { fatalError() }
let url = URL(fileURLWithPath: "Build/menubar_preview.png") as CFURL
guard let dest = CGImageDestinationCreateWithURL(url, kUTTypePNG, 1, nil) else { fatalError() }
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("✓ Build/menubar_preview.png")
