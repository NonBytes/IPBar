#!/usr/bin/env swift
// Renders the IPBar app icon: a location pin holding "IP" sitting on a globe,
// drawn as clean line-art on a light squircle, at all iconset sizes.
// Usage: swift Tools/make_icon.swift  ->  writes IPBar.iconset/*.png
import AppKit
import CoreGraphics
import CoreText
import Foundation

let cs = CGColorSpaceCreateDeviceRGB()
func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(a)])!
}

let bgColor  = rgb(0.97, 0.98, 1.00)
let ink      = rgb(0.10, 0.11, 0.13)

/// Draw a string centred at `center` using a bold font, filled with `color`.
func drawIP(_ s: String, center: CGPoint, fontSize: CGFloat, color: CGColor, in ctx: CGContext) {
    let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    ctx.saveGState()
    ctx.textMatrix = .identity
    ctx.textPosition = CGPoint(x: center.x - b.width / 2 - b.origin.x,
                               y: center.y - b.height / 2 - b.origin.y)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func drawIcon(in ctx: CGContext, size S: CGFloat) {
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // --- background squircle (macOS grid: ~80% of canvas, ~22% corner radius) ---
    let margin = S * 0.0977
    let side = S - 2 * margin
    let rrect = CGRect(x: margin, y: margin, width: side, height: side)
    let radius = side * 0.2247
    let bg = CGPath(roundedRect: rrect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(bg); ctx.clip()
    ctx.setFillColor(bgColor)
    ctx.fill(rrect)
    ctx.restoreGState()

    let cx = margin + side / 2

    // --- geometry: a single centred location pin ---
    let pc   = CGPoint(x: cx, y: margin + side * 0.615)   // pin head centre
    let Rh   = side * 0.285                                // pin head radius
    let tipY = margin + side * 0.105                       // pin tip
    let Ri   = Rh * 0.60                                   // inner ring radius
    let ringW = side * 0.030
    let pinW  = side * 0.034

    // tangent points from the tip to the head circle
    let d = pc.y - tipY
    let beta = acos(Rh / d)
    let aRight = -CGFloat.pi / 2 + beta            // right tangent point angle
    let aLeft  =  3 * CGFloat.pi / 2 - beta        // left tangent point (swept ccw over the top)
    let tip = CGPoint(x: cx, y: tipY)
    let pRight = CGPoint(x: pc.x + Rh * cos(aRight), y: pc.y + Rh * sin(aRight))

    let pin = CGMutablePath()
    pin.move(to: tip)
    pin.addLine(to: pRight)
    pin.addArc(center: pc, radius: Rh, startAngle: aRight, endAngle: aLeft, clockwise: false)
    pin.closeSubpath()

    // pin body: white interior + stroked outline
    ctx.saveGState()
    ctx.addPath(pin); ctx.setFillColor(bgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.setStrokeColor(ink); ctx.setLineWidth(pinW)
    ctx.addPath(pin); ctx.strokePath()

    // inner ring + "IP"
    let innerRect = CGRect(x: pc.x - Ri, y: pc.y - Ri, width: 2 * Ri, height: 2 * Ri)
    ctx.setFillColor(bgColor); ctx.addEllipse(in: innerRect); ctx.fillPath()
    ctx.setLineWidth(ringW); ctx.setStrokeColor(ink)
    ctx.addEllipse(in: innerRect); ctx.strokePath()

    drawIP("IP", center: pc, fontSize: Ri * 1.30, color: ink, in: ctx)
}

func renderPNG(pixels: Int, to url: URL) {
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels,
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    drawIcon(in: ctx, size: CGFloat(pixels))
    guard let cg = ctx.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: cg)
    rep.size = NSSize(width: pixels, height: pixels)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: url)
}

let fm = FileManager.default
let outDir = URL(fileURLWithPath: "IPBar.iconset")
try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)

let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in entries {
    renderPNG(pixels: px, to: outDir.appendingPathComponent("\(name).png"))
    print("rendered \(name).png (\(px)px)")
}
print("done -> IPBar.iconset")
