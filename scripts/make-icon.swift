#!/usr/bin/env swift
// Generates Resources/AppIcon.icns for PitStop.
//
// Design: a dark rounded tile with a speedometer-style usage gauge — gray
// track, amber + red zones at the high end, Claude-coral needle sitting just
// shy of the red zone ("time to pit") — over a checkered pit-lane strip.
// Everything is drawn in a 1024-unit space and re-rendered per icon size, so
// edges stay crisp at every resolution.
//
// Usage:  swift scripts/make-icon.swift
// Output: Resources/AppIcon.icns (plus the intermediate .iconset)

import AppKit

// MARK: - Palette

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

let tileTop = rgb(0x2E2E36)
let tileBottom = rgb(0x161619)
let dialFace = rgb(0x26262E)
let bezel = rgb(0x60606B)
let track = rgb(0x4A4A56)
let amber = rgb(0xE8A33D)
let red = rgb(0xE5484D)
let tick = rgb(0xECECF1, 0.92)
let coral = rgb(0xD97757)          // Claude brand coral — the needle
let checkerLight = rgb(0xE9E9EE)
let checkerDark = rgb(0x141417)

// MARK: - Geometry (1024-unit space)

let canvas: CGFloat = 1024
let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tileRadius: CGFloat = 186      // Apple's Big Sur+ icon-grid corner radius
let dialCenter = CGPoint(x: 512, y: 600)
let dialRadius: CGFloat = 300

func deg(_ d: CGFloat) -> CGFloat { d * .pi / 180 }
/// Gauge sweep: 0% at 225°, 100% at -45° (a 270° speedometer arc).
func angle(at fraction: CGFloat) -> CGFloat { 225 - 270 * fraction }

// MARK: - Drawing

func draw(in cg: CGContext) {
    let tile = CGPath(roundedRect: tileRect, cornerWidth: tileRadius,
                      cornerHeight: tileRadius, transform: nil)

    // Tile with soft drop shadow
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 40,
                 color: CGColor(gray: 0, alpha: 0.35))
    cg.addPath(tile)
    cg.setFillColor(tileBottom)
    cg.fillPath()
    cg.restoreGState()

    // Vertical gradient inside the tile
    cg.saveGState()
    cg.addPath(tile)
    cg.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [tileTop, tileBottom] as CFArray,
                              locations: [0, 1])!
    cg.drawLinearGradient(gradient,
                          start: CGPoint(x: 512, y: tileRect.maxY),
                          end: CGPoint(x: 512, y: tileRect.minY),
                          options: [])

    // Checkered pit-lane strip along the bottom (still clipped to the tile)
    let columns = 12
    let square = tileRect.width / CGFloat(columns)
    for row in 0..<2 {
        for col in 0..<columns {
            cg.setFillColor((row + col) % 2 == 0 ? checkerDark : checkerLight)
            cg.fill(CGRect(x: tileRect.minX + CGFloat(col) * square,
                           y: tileRect.minY + CGFloat(row) * square,
                           width: square, height: square))
        }
    }
    cg.restoreGState()

    // Dial face + bezel
    cg.setFillColor(dialFace)
    cg.fillEllipse(in: CGRect(x: dialCenter.x - dialRadius,
                              y: dialCenter.y - dialRadius,
                              width: dialRadius * 2, height: dialRadius * 2))
    cg.setStrokeColor(bezel)
    cg.setLineWidth(13)
    cg.strokeEllipse(in: CGRect(x: dialCenter.x - dialRadius,
                                y: dialCenter.y - dialRadius,
                                width: dialRadius * 2, height: dialRadius * 2))

    // Usage zones: gray track 0–65%, amber 65–85%, red 85–100%
    let zoneRadius: CGFloat = 252
    func zone(_ from: CGFloat, _ to: CGFloat, _ color: CGColor) {
        cg.setStrokeColor(color)
        cg.setLineWidth(30)
        cg.setLineCap(.butt)
        cg.addArc(center: dialCenter, radius: zoneRadius,
                  startAngle: deg(angle(at: from)), endAngle: deg(angle(at: to)),
                  clockwise: true)
        cg.strokePath()
    }
    zone(0.00, 0.65, track)
    zone(0.65, 0.85, amber)
    zone(0.85, 1.00, red)

    // Major ticks (9 across the sweep), inside the zone arc
    cg.setStrokeColor(tick)
    cg.setLineWidth(11)
    cg.setLineCap(.round)
    for t in 0...8 {
        let a = deg(angle(at: CGFloat(t) / 8))
        let inner: CGFloat = 188, outer: CGFloat = 222
        cg.move(to: CGPoint(x: dialCenter.x + inner * cos(a),
                            y: dialCenter.y + inner * sin(a)))
        cg.addLine(to: CGPoint(x: dialCenter.x + outer * cos(a),
                               y: dialCenter.y + outer * sin(a)))
        cg.strokePath()
    }

    // Needle at ~78% — just shy of the red zone: time to pit
    let needleAngle = deg(angle(at: 0.78))
    cg.saveGState()
    cg.translateBy(x: dialCenter.x, y: dialCenter.y)
    cg.rotate(by: needleAngle)
    let needle = CGMutablePath()
    needle.move(to: CGPoint(x: -62, y: 16))
    needle.addLine(to: CGPoint(x: 238, y: 6))
    needle.addLine(to: CGPoint(x: 252, y: 0))
    needle.addLine(to: CGPoint(x: 238, y: -6))
    needle.addLine(to: CGPoint(x: -62, y: -16))
    needle.closeSubpath()
    cg.addPath(needle)
    cg.setFillColor(coral)
    cg.setShadow(offset: .zero, blur: 18, color: rgb(0xD97757, 0.45))
    cg.fillPath()
    cg.restoreGState()

    // Hub
    cg.setFillColor(coral)
    cg.fillEllipse(in: CGRect(x: dialCenter.x - 36, y: dialCenter.y - 36,
                              width: 72, height: 72))
    cg.setFillColor(dialFace)
    cg.fillEllipse(in: CGRect(x: dialCenter.x - 13, y: dialCenter.y - 13,
                              width: 26, height: 26))
}

// MARK: - Rendering

func render(px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px,
                               pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    cg.scaleBy(x: CGFloat(px) / canvas, y: CGFloat(px) / canvas)
    draw(in: cg)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// MARK: - Iconset + icns

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let projectRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let iconset = projectRoot.appendingPathComponent("Resources/AppIcon.iconset")
let icns = projectRoot.appendingPathComponent("Resources/AppIcon.icns")

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let entries: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for entry in entries {
    try render(px: entry.px)
        .write(to: iconset.appendingPathComponent("\(entry.name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(iconutil.terminationStatus)")
}
print("Wrote \(icns.path)")
