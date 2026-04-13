#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

// Renders the DiskLens app icon: a hard-disk platter overlaid with a treemap
// pattern and a magnifying-glass lens. Outputs an .iconset directory ready
// for `iconutil --convert icns`.

let outDir = CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir,
                                          withIntermediateDirectories: true)

struct Block { let x: CGFloat; let y: CGFloat; let w: CGFloat; let h: CGFloat; let color: NSColor }

func iconBlocks() -> [Block] {
    // A small fixed treemap pattern that scales with the canvas.
    let palette: [NSColor] = [
        NSColor(red: 0.95, green: 0.30, blue: 0.45, alpha: 1),
        NSColor(red: 0.90, green: 0.55, blue: 0.20, alpha: 1),
        NSColor(red: 0.95, green: 0.80, blue: 0.20, alpha: 1),
        NSColor(red: 0.35, green: 0.75, blue: 0.95, alpha: 1),
        NSColor(red: 0.40, green: 0.85, blue: 0.50, alpha: 1),
        NSColor(red: 0.65, green: 0.40, blue: 0.85, alpha: 1),
        NSColor(red: 0.30, green: 0.55, blue: 0.95, alpha: 1),
        NSColor(red: 0.20, green: 0.80, blue: 0.75, alpha: 1),
    ]
    // Fractions of the unit square; the renderer multiplies by canvas size.
    let raw: [(CGFloat, CGFloat, CGFloat, CGFloat, Int)] = [
        (0.00, 0.00, 0.55, 0.55, 0), // big red
        (0.55, 0.00, 0.45, 0.30, 3), // sky doc
        (0.55, 0.30, 0.45, 0.25, 4), // green code
        (0.00, 0.55, 0.30, 0.45, 1), // orange
        (0.30, 0.55, 0.25, 0.20, 2), // yellow
        (0.55, 0.55, 0.45, 0.25, 6), // blue app
        (0.30, 0.75, 0.25, 0.25, 5), // purple
        (0.55, 0.80, 0.45, 0.20, 7), // teal
    ]
    return raw.map { Block(x: $0.0, y: $0.1, w: $0.2, h: $0.3, color: palette[$0.4]) }
}

func render(size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    // Rounded-rect background (macOS app icon "squircle" feel).
    let cornerRadius = s * 0.225
    let outerRect = CGRect(x: 0, y: 0, width: s, height: s)
        .insetBy(dx: s * 0.08, dy: s * 0.08)
    let bgPath = CGPath(roundedRect: outerRect,
                        cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                        transform: nil)
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()

    // Backdrop gradient (deep navy → indigo).
    let colors = [
        NSColor(red: 0.10, green: 0.12, blue: 0.20, alpha: 1).cgColor,
        NSColor(red: 0.18, green: 0.10, blue: 0.32, alpha: 1).cgColor
    ] as CFArray
    let space = CGColorSpaceCreateDeviceRGB()
    let grad = CGGradient(colorsSpace: space, colors: colors,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: outerRect.minX, y: outerRect.maxY),
                           end: CGPoint(x: outerRect.maxX, y: outerRect.minY),
                           options: [])

    // Inner padding for the treemap pattern.
    let pad = s * 0.06
    let inner = outerRect.insetBy(dx: pad, dy: pad)
    let blocks = iconBlocks()

    func cushion(_ rect: CGRect, color: NSColor) {
        let path = CGPath(roundedRect: rect.insetBy(dx: 1, dy: 1),
                          cornerWidth: max(2, s * 0.012),
                          cornerHeight: max(2, s * 0.012),
                          transform: nil)
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.setFillColor(color.cgColor)
        ctx.fill(rect)
        // Highlight gradient.
        let hi = CGGradient(colorsSpace: space, colors: [
            NSColor(white: 1, alpha: 0.55).cgColor,
            NSColor(white: 1, alpha: 0.0).cgColor,
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(hi,
                               start: CGPoint(x: rect.minX, y: rect.maxY),
                               end: CGPoint(x: rect.midX, y: rect.midY),
                               options: [])
        // Shadow.
        let lo = CGGradient(colorsSpace: space, colors: [
            NSColor(white: 0, alpha: 0.0).cgColor,
            NSColor(white: 0, alpha: 0.45).cgColor,
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(lo,
                               start: CGPoint(x: rect.midX, y: rect.midY),
                               end: CGPoint(x: rect.maxX, y: rect.minY),
                               options: [])
        ctx.restoreGState()
        // Border.
        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.5).cgColor)
        ctx.setLineWidth(max(0.5, s * 0.003))
        ctx.addPath(path)
        ctx.strokePath()
    }

    for b in blocks {
        let r = CGRect(x: inner.minX + b.x * inner.width,
                       y: inner.minY + (1 - b.y - b.h) * inner.height,
                       width: b.w * inner.width,
                       height: b.h * inner.height)
        cushion(r, color: b.color)
    }

    ctx.restoreGState() // pop background clip

    // Magnifying glass.
    let lensRadius = s * 0.22
    let lensCenter = CGPoint(x: outerRect.maxX - lensRadius - s * 0.10,
                              y: outerRect.minY + lensRadius + s * 0.10)
    // Shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012),
                  blur: s * 0.04,
                  color: NSColor(white: 0, alpha: 0.5).cgColor)
    // Lens ring.
    let ringWidth = s * 0.045
    let ringRect = CGRect(x: lensCenter.x - lensRadius,
                          y: lensCenter.y - lensRadius,
                          width: lensRadius * 2,
                          height: lensRadius * 2)
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(ringWidth)
    ctx.strokeEllipse(in: ringRect)

    // Lens glass fill (slightly tinted, semi-transparent).
    ctx.setFillColor(NSColor(white: 0.9, alpha: 0.18).cgColor)
    ctx.fillEllipse(in: ringRect.insetBy(dx: ringWidth / 2, dy: ringWidth / 2))

    // Highlight on the lens.
    ctx.saveGState()
    let glassPath = CGPath(ellipseIn: ringRect.insetBy(dx: ringWidth / 2,
                                                        dy: ringWidth / 2),
                            transform: nil)
    ctx.addPath(glassPath); ctx.clip()
    let glassHi = CGGradient(colorsSpace: space, colors: [
        NSColor(white: 1, alpha: 0.55).cgColor,
        NSColor(white: 1, alpha: 0.0).cgColor,
    ] as CFArray, locations: [0, 0.7])!
    ctx.drawRadialGradient(glassHi,
                           startCenter: CGPoint(x: lensCenter.x - lensRadius * 0.4,
                                                y: lensCenter.y + lensRadius * 0.4),
                           startRadius: 0,
                           endCenter: CGPoint(x: lensCenter.x - lensRadius * 0.4,
                                              y: lensCenter.y + lensRadius * 0.4),
                           endRadius: lensRadius,
                           options: [])
    ctx.restoreGState()

    // Handle.
    let handleStart = CGPoint(x: lensCenter.x + lensRadius * 0.70,
                              y: lensCenter.y - lensRadius * 0.70)
    let handleEnd = CGPoint(x: lensCenter.x + lensRadius * 1.55,
                            y: lensCenter.y - lensRadius * 1.55)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(s * 0.06)
    ctx.move(to: handleStart)
    ctx.addLine(to: handleEnd)
    ctx.strokePath()

    ctx.restoreGState()

    // Outer subtle stroke for shape definition.
    ctx.setStrokeColor(NSColor(white: 0, alpha: 0.35).cgColor)
    ctx.setLineWidth(max(0.5, s * 0.004))
    ctx.addPath(bgPath)
    ctx.strokePath()

    image.unlockFocus()
    return image
}

func savePNG(_ image: NSImage, to path: String) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("Failed to encode PNG\n".data(using: .utf8)!)
        return
    }
    try? data.write(to: URL(fileURLWithPath: path))
}

// macOS .iconset required sizes.
let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, px) in sizes {
    let img = render(size: px)
    savePNG(img, to: "\(outDir)/\(name)")
    print("Wrote \(outDir)/\(name)")
}
