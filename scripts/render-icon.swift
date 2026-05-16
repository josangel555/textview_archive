#!/usr/bin/env swift
// Render the MarkdownViewer app icon (hex-mesh design) as PNGs at all
// the sizes macOS needs for an iconset, then let `iconutil` wrap them
// into an .icns.
//
// Output: ./scripts/AppIcon.iconset/{icon_16x16.png, icon_16x16@2x.png, …}
//
// Design source: file:///Users/me/Downloads/TextView (2)/app-icon.html
// (variant A — hex mesh, the chosen one). Reproduced in Core Graphics
// so the icon is committed as Swift, not a binary asset that drifts
// from the design without anyone noticing.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Geometry

/// Reference canvas is 1024×1024. All hard-coded coordinates assume
/// this; the renderer scales the context for smaller outputs so the
/// math reads cleanly in design units.
let canvas: CGFloat = 1024

let centerX: CGFloat = 512
let centerY: CGFloat = 512
let outerRadius: CGFloat = 280      // distance from center to each outer node
let nodeRadius: CGFloat = 38
let nodeHaloRadius: CGFloat = 90
let centerDotRadius: CGFloat = 48
let centerGlowRadius: CGFloat = 220
let filamentWidth: CGFloat = 7
let perimeterWidth: CGFloat = 3
let cornerFraction: CGFloat = 0.224  // squircle corner radius / edge

// Six outer node positions, top first (90°), CW.
func hexNodes() -> [CGPoint] {
    (0..<6).map { i in
        let angle = (.pi / 2) - CGFloat(i) * (.pi / 3)
        return CGPoint(x: centerX + outerRadius * cos(angle),
                       y: centerY - outerRadius * sin(angle))
    }
}

// MARK: - Drawing

/// macOS-style rounded squircle. `CGPath.init(roundedRect:…)` produces
/// a circular-arc-cornered rectangle which, at the corner ratio used
/// for macOS app icons (22.4% of edge), is visually indistinguishable
/// from Apple's continuous-corner squircle at icon scales. Apple's
/// own icon templates use the same approximation.
func squirclePath(in rect: CGRect) -> CGPath {
    let r = rect.width * cornerFraction
    return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r,
                  transform: nil)
}

func drawIcon(into ctx: CGContext, size: CGFloat) {
    let scale = size / canvas
    ctx.saveGState()
    ctx.scaleBy(x: scale, y: scale)

    // Flip Y so design coords (y-down) match Core Graphics (y-up) —
    // simpler than re-deriving every gradient.
    ctx.translateBy(x: 0, y: canvas)
    ctx.scaleBy(x: 1, y: -1)

    // Clip to squircle.
    let canvasRect = CGRect(x: 0, y: 0, width: canvas, height: canvas)
    ctx.addPath(squirclePath(in: canvasRect))
    ctx.clip()

    // Background gradient: 135° (top-left → bottom-right). Three stops.
    let bgColors: [CGColor] = [
        CGColor(red: 0x3a/255, green: 0x76/255, blue: 0xb8/255, alpha: 1),
        CGColor(red: 0x1f/255, green: 0x4d/255, blue: 0x8a/255, alpha: 1),
        CGColor(red: 0x0e/255, green: 0x24/255, blue: 0x40/255, alpha: 1),
    ]
    let bgLocations: [CGFloat] = [0.0, 0.55, 1.0]
    let space = CGColorSpaceCreateDeviceRGB()
    if let bg = CGGradient(colorsSpace: space, colors: bgColors as CFArray,
                           locations: bgLocations) {
        ctx.drawLinearGradient(
            bg,
            start: CGPoint(x: 0, y: 0),
            end:   CGPoint(x: canvas, y: canvas),
            options: []
        )
    }

    // Highlight radial at top-left (per design: cx=28%, cy=22%, r=55%).
    let hiCenter = CGPoint(x: canvas * 0.28, y: canvas * 0.22)
    let hiR = canvas * 0.55
    let hiColors: [CGColor] = [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.04),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
    ]
    let hiLocations: [CGFloat] = [0.0, 0.60, 1.0]
    if let hi = CGGradient(colorsSpace: space, colors: hiColors as CFArray,
                           locations: hiLocations) {
        ctx.drawRadialGradient(
            hi,
            startCenter: hiCenter, startRadius: 0,
            endCenter:   hiCenter, endRadius:   hiR,
            options: []
        )
    }

    let nodes = hexNodes()

    // Perimeter hexagon ring.
    ctx.setStrokeColor(red: 0xcf/255, green: 0xe2/255, blue: 0xff/255, alpha: 0.10)
    ctx.setLineWidth(perimeterWidth)
    ctx.setLineJoin(.round)
    ctx.beginPath()
    for (i, n) in nodes.enumerated() {
        if i == 0 { ctx.move(to: n) } else { ctx.addLine(to: n) }
    }
    ctx.closePath()
    ctx.strokePath()

    // Filaments: center → each outer node.
    ctx.setStrokeColor(red: 0xcf/255, green: 0xe2/255, blue: 0xff/255, alpha: 0.22)
    ctx.setLineWidth(filamentWidth)
    ctx.setLineCap(.round)
    for n in nodes {
        ctx.beginPath()
        ctx.move(to: CGPoint(x: centerX, y: centerY))
        ctx.addLine(to: n)
        ctx.strokePath()
    }

    // Outer node halos (soft radial blue glow).
    let haloColors: [CGColor] = [
        CGColor(red: 0xcf/255, green: 0xe2/255, blue: 0xff/255, alpha: 0.40),
        CGColor(red: 0xcf/255, green: 0xe2/255, blue: 0xff/255, alpha: 0.0),
    ]
    if let halo = CGGradient(colorsSpace: space, colors: haloColors as CFArray,
                             locations: [0, 1]) {
        for n in nodes {
            ctx.drawRadialGradient(
                halo,
                startCenter: n, startRadius: 0,
                endCenter:   n, endRadius:   nodeHaloRadius,
                options: []
            )
        }
    }

    // Outer node solid markers (cool light blue with white inset).
    for n in nodes {
        ctx.setFillColor(red: 0xdb/255, green: 0xe8/255, blue: 0xf5/255, alpha: 1)
        ctx.fillEllipse(in: CGRect(x: n.x - nodeRadius, y: n.y - nodeRadius,
                                    width: nodeRadius * 2, height: nodeRadius * 2))
        let inner = nodeRadius - 3
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.96)
        ctx.fillEllipse(in: CGRect(x: n.x - inner, y: n.y - inner,
                                    width: inner * 2, height: inner * 2))
    }

    // Center glow + dot.
    let centerPt = CGPoint(x: centerX, y: centerY)
    let glowColors: [CGColor] = [
        CGColor(red: 0xfd/255, green: 0xf6/255, blue: 0xe3/255, alpha: 0.55),
        CGColor(red: 0xfd/255, green: 0xf6/255, blue: 0xe3/255, alpha: 0.18),
        CGColor(red: 0xfd/255, green: 0xf6/255, blue: 0xe3/255, alpha: 0.0),
    ]
    if let glow = CGGradient(colorsSpace: space, colors: glowColors as CFArray,
                             locations: [0, 0.4, 1]) {
        ctx.drawRadialGradient(
            glow,
            startCenter: centerPt, startRadius: 0,
            endCenter:   centerPt, endRadius:   centerGlowRadius,
            options: []
        )
    }
    ctx.setFillColor(red: 0xfd/255, green: 0xf6/255, blue: 0xe3/255, alpha: 1)
    ctx.fillEllipse(in: CGRect(x: centerX - centerDotRadius, y: centerY - centerDotRadius,
                                width: centerDotRadius * 2, height: centerDotRadius * 2))
    let innerDot = centerDotRadius - 4
    ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.6)
    ctx.fillEllipse(in: CGRect(x: centerX - innerDot, y: centerY - innerDot,
                                width: innerDot * 2, height: innerDot * 2))

    ctx.restoreGState()
}

// MARK: - PNG encoding

func renderPNG(size pixels: Int, to url: URL) throws {
    let bytesPerRow = pixels * 4
    guard let ctx = CGContext(
        data: nil,
        width: pixels, height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "render", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "CGContext failed at \(pixels)px"])
    }
    drawIcon(into: ctx, size: CGFloat(pixels))
    guard let image = ctx.makeImage() else {
        throw NSError(domain: "render", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "makeImage failed at \(pixels)px"])
    }
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "render", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "PNG encode failed at \(pixels)px"])
    }
    try data.write(to: url)
}

// MARK: - Driver

let outDir: URL = {
    let args = CommandLine.arguments
    if args.count > 1 { return URL(fileURLWithPath: args[1]) }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("scripts/AppIcon.iconset")
}()

try? FileManager.default.createDirectory(at: outDir,
                                         withIntermediateDirectories: true)

// (filename, actual pixel size). iconutil expects the @2x variants
// at exactly 2× the named edge.
let entries: [(String, Int)] = [
    ("icon_16x16.png",      16),
    ("icon_16x16@2x.png",   32),
    ("icon_32x32.png",      32),
    ("icon_32x32@2x.png",   64),
    ("icon_128x128.png",   128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",   256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",   512),
    ("icon_512x512@2x.png", 1024),
]

for (name, px) in entries {
    let url = outDir.appendingPathComponent(name)
    try renderPNG(size: px, to: url)
    FileHandle.standardError.write(Data("rendered \(name) (\(px)px)\n".utf8))
}

FileHandle.standardError.write(Data("→ \(outDir.path)\n".utf8))
