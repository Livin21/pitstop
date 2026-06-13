#!/usr/bin/swift
// Generates docs/social-preview.png (1280×640) for GitHub's repository
// social preview: icon + wordmark + tagline on the left, the README menu
// screenshot on the right, checkered pit-lane strip along the bottom.
// Inputs: docs/icon.png and docs/menu.png (regenerate via make-icon.swift
// and the --screenshot flag first if stale).
import AppKit

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let projectRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let docs = projectRoot.appendingPathComponent("docs")

guard let icon = NSImage(contentsOf: docs.appendingPathComponent("icon.png")),
      let menu = NSImage(contentsOf: docs.appendingPathComponent("menu.png")) else {
    fatalError("docs/icon.png and docs/menu.png are required")
}

let width = 1280, height = 640
let coral = NSColor(srgbRed: 217 / 255, green: 119 / 255, blue: 87 / 255, alpha: 1)

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high

// Background gradient
NSGradient(starting: NSColor(srgbRed: 0.165, green: 0.169, blue: 0.193, alpha: 1),
           ending: NSColor(srgbRed: 0.078, green: 0.082, blue: 0.098, alpha: 1))!
    .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

// Checkered pit-lane strip (two rows, like the app icon's bottom band)
let square = 20
for row in 0..<2 {
    for col in 0...(width / square) {
        ((col + row) % 2 == 0 ? NSColor(white: 0.88, alpha: 1) : NSColor(white: 0.07, alpha: 1)).setFill()
        NSRect(x: col * square, y: row * square, width: square, height: square).fill()
    }
}

// Menu screenshot, right side (its own window shadow is baked in). Scale to a
// target height so it's robust to the capture's exact pixel dimensions.
let targetMenuHeight: CGFloat = 544
let menuScale = targetMenuHeight / menu.size.height
let menuSize = NSSize(width: menu.size.width * menuScale, height: targetMenuHeight)
let menuRect = NSRect(x: CGFloat(width) - menuSize.width - 64,
                      y: 40 + (CGFloat(height) - 40 - menuSize.height) / 2,
                      width: menuSize.width, height: menuSize.height)
menu.draw(in: menuRect, from: .zero, operation: .sourceOver, fraction: 1)

// Left column: icon, wordmark, coral accent, tagline
let columnCenter = (CGFloat(width) - menuSize.width - 64 + 24) / 2

let iconSide: CGFloat = 150
icon.draw(in: NSRect(x: columnCenter - iconSide / 2, y: 386,
                     width: iconSide, height: iconSide),
          from: .zero, operation: .sourceOver, fraction: 1)

let center = NSMutableParagraphStyle()
center.alignment = .center

let title = "PitStop" as NSString
title.draw(in: NSRect(x: columnCenter - 280, y: 262, width: 560, height: 110),
           withAttributes: [
               .font: NSFont.systemFont(ofSize: 84, weight: .bold),
               .foregroundColor: NSColor.white,
               .paragraphStyle: center,
           ])

coral.setFill()
NSBezierPath(roundedRect: NSRect(x: columnCenter - 70, y: 244, width: 140, height: 7),
             xRadius: 3.5, yRadius: 3.5).fill()

let tagline = "Usage limits + one-click account switching\nfor Claude Code, Claude Desktop & Codex" as NSString
tagline.draw(in: NSRect(x: columnCenter - 280, y: 132, width: 560, height: 92),
             withAttributes: [
                 .font: NSFont.systemFont(ofSize: 26, weight: .regular),
                 .foregroundColor: NSColor(srgbRed: 0.72, green: 0.73, blue: 0.76, alpha: 1),
                 .paragraphStyle: center,
             ])

NSGraphicsContext.restoreGraphicsState()
let out = docs.appendingPathComponent("social-preview.png")
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("Wrote \(out.path)")
