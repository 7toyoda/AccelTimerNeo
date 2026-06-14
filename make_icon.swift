#!/usr/bin/env swift
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let bounds = CGRect(x: 0, y: 0, width: size, height: size)

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

// --- 背景グラデーション ---
let bgColors = [CGColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1),
                CGColor(red: 0.10, green: 0.10, blue: 0.15, alpha: 1)]
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: bgColors as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: size/2, y: size),
                       end:   CGPoint(x: size/2, y: 0),
                       options: [])

// --- 角丸マスク（iOS アイコン形状に近い） ---
// Xcode が自動でマスクするので省略

// --- スピードメーター円弧 ---
let center = CGPoint(x: size / 2, y: size / 2 - 30)
let radius: CGFloat = 340
let lineWidth: CGFloat = 42

// 背景弧（暗いグレー）
ctx.setLineWidth(lineWidth)
ctx.setLineCap(.round)
ctx.setStrokeColor(CGColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1))
let startAngle = CGFloat.pi * 0.75    // 左下から
let endAngle   = CGFloat.pi * 0.25    // 右下まで（時計回り）
// CGContext: 反時計回りが正方向なので clockwise=true で時計回り
ctx.addArc(center: center, radius: radius,
           startAngle: startAngle, endAngle: endAngle,
           clockwise: true)
ctx.strokePath()

// 進行弧（赤→黄グラデーション）
let arcColors  = [CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1),
                  CGColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1)]
let arcGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: arcColors as CFArray,
                              locations: [0, 1])!

// 弧をパスでクリップしてグラデーション描画
ctx.saveGState()
ctx.setLineWidth(lineWidth)
ctx.setLineCap(.round)
let arcPath = CGMutablePath()
arcPath.addArc(center: center, radius: radius,
               startAngle: startAngle, endAngle: endAngle,
               clockwise: true)
// パスをストロークしてクリップ
ctx.addPath(arcPath)
// グラデーション弧を手動で描くため、複数セグメントで近似
let steps = 60
let totalAngle = (2 * CGFloat.pi - (endAngle - startAngle))
for i in 0..<steps {
    let t0 = CGFloat(i)     / CGFloat(steps)
    let t1 = CGFloat(i + 1) / CGFloat(steps)
    let a0 = startAngle - totalAngle * t0
    let a1 = startAngle - totalAngle * t1
    let r  = t0
    let g  = 0.2 + 0.6 * r
    let b  = 0.1 * (1 - r)
    ctx.setStrokeColor(CGColor(red: 1.0 - r * 0.1,
                                green: 0.2 + 0.6 * r,
                                blue: 0.1 * (1 - r),
                                alpha: 1))
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(i == 0 ? .round : .butt)
    ctx.addArc(center: center, radius: radius,
               startAngle: a0, endAngle: a1, clockwise: true)
    ctx.strokePath()
}
ctx.restoreGState()

// --- 針 ---
let needleAngle = endAngle + 0.05  // ほぼ右下（100 km/h 位置）
let needleLen: CGFloat = 300
ctx.saveGState()
ctx.translateBy(x: center.x, y: center.y)
ctx.rotate(by: needleAngle)
ctx.setLineWidth(10)
ctx.setLineCap(.round)
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
ctx.move(to: CGPoint(x: -60, y: 0))
ctx.addLine(to: CGPoint(x: needleLen, y: 0))
ctx.strokePath()
// 中心ドット
ctx.setFillColor(CGColor(red: 1, green: 0.8, blue: 0, alpha: 1))
ctx.addEllipse(in: CGRect(x: -22, y: -22, width: 44, height: 44))
ctx.fillPath()
ctx.restoreGState()

// --- "0-100" テキスト ---
let paraStyle = NSMutableParagraphStyle()
paraStyle.alignment = .center

let topText = "0-100" as NSString
let topAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 130, weight: .black),
    .foregroundColor: NSColor.white,
    .paragraphStyle: paraStyle
]
let topRect = CGRect(x: 0, y: 200, width: size, height: 160)
topText.draw(in: topRect, withAttributes: topAttrs)

// --- "km/h" テキスト ---
let subText = "km/h" as NSString
let subAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 72, weight: .semibold),
    .foregroundColor: NSColor(red: 1, green: 0.75, blue: 0, alpha: 1),
    .paragraphStyle: paraStyle
]
let subRect = CGRect(x: 0, y: 120, width: size, height: 100)
subText.draw(in: subRect, withAttributes: subAttrs)

image.unlockFocus()

// PNG 書き出し
let outPath = "/Users/user01/dev/AccelTimer/icon_1024.png"
if let tiff = image.tiffRepresentation,
   let rep  = NSBitmapImageRep(data: tiff),
   let png  = rep.representation(using: .png, properties: [:]) {
    try! png.write(to: URL(fileURLWithPath: outPath))
    print("生成完了: \(outPath)")
} else {
    print("エラー: PNG生成失敗")
}
