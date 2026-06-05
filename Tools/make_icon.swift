#!/usr/bin/env swift
// Renders the IPBar app icon (macOS squircle + globe) at all iconset sizes.
// Usage: swift Tools/make_icon.swift  ->  writes IPBar.iconset/*.png
import AppKit
import CoreGraphics

let cs = CGColorSpaceCreateDeviceRGB()
func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(a)])!
}

func drawIcon(in ctx: CGContext, size: CGFloat) {
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // --- background squircle (macOS icon grid: ~80% of canvas, ~22% corner radius) ---
    let margin = size * 0.0977
    let side = size - 2 * margin
    let rrect = CGRect(x: margin, y: margin, width: side, height: side)
    let radius = side * 0.2247
    let bg = CGPath(roundedRect: rrect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(bg); ctx.clip()
    let grad = CGGradient(colorsSpace: cs,
                          colors: [rgb(0.33, 0.62, 1.00), rgb(0.17, 0.23, 0.80)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: 0, y: size),
                           end: CGPoint(x: 0, y: 0), options: [])
    // soft top-left gloss
    let gloss = CGPoint(x: margin + side * 0.30, y: margin + side * 0.76)
    let glossGrad = CGGradient(colorsSpace: cs,
                               colors: [rgb(1, 1, 1, 0.28), rgb(1, 1, 1, 0)] as CFArray,
                               locations: [0, 1])!
    ctx.drawRadialGradient(glossGrad, startCenter: gloss, startRadius: 0,
                           endCenter: gloss, endRadius: side * 0.62, options: [])
    ctx.restoreGState()

    // --- globe ---
    let c = CGPoint(x: size / 2, y: size / 2)
    let R = side * 0.300
    let white = rgb(1, 1, 1, 0.96)
    ctx.setStrokeColor(white)
    ctx.setLineCap(.round)

    // grid lines, clipped to the globe disc
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
    ctx.clip()
    ctx.setLineWidth(side * 0.015)

    // equator + prime meridian
    ctx.move(to: CGPoint(x: c.x, y: c.y - R)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + R))
    ctx.move(to: CGPoint(x: c.x - R, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + R, y: c.y))
    ctx.strokePath()

    // meridians (vertical ellipses)
    for rx in [R * 0.58, R * 0.30] {
        ctx.addEllipse(in: CGRect(x: c.x - rx, y: c.y - R, width: 2 * rx, height: 2 * R))
        ctx.strokePath()
    }
    // latitudes (horizontal ellipses)
    for ry in [R * 0.58, R * 0.30] {
        ctx.addEllipse(in: CGRect(x: c.x - R, y: c.y - ry, width: 2 * R, height: 2 * ry))
        ctx.strokePath()
    }
    ctx.restoreGState()

    // outer ring on top
    ctx.setLineWidth(side * 0.020)
    ctx.addEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
    ctx.strokePath()
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
