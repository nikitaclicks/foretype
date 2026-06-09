#!/usr/bin/env swift

// Renders the Foretype app icon as a 1024×1024 master PNG.
//
// Motif: an I-beam text caret (the menu-bar identity is the `text.cursor`
// SF Symbol) followed by faded "ghost text" word blocks — the literal
// inline-autocomplete gesture the app performs.
//
// Usage: swift scripts/make-icon.swift <output.png>
// Downscaling to the per-size icon slices is handled by make-icon.sh.

import AppKit

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "icon-master.png"

let S: CGFloat = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// --- Squircle background (Big Sur grid: 824×824 inset, ~22.37% corner radius) ---
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let radius = rect.width * 0.2237
let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
squircle.addClip()

let top = CGColor(red: 0.40, green: 0.38, blue: 0.95, alpha: 1)      // indigo
let bottom = CGColor(red: 0.27, green: 0.22, blue: 0.78, alpha: 1)   // deep violet
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [top, bottom] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0),
    options: [])

// --- Foreground glyphs ---
let cy = S / 2
let white = NSColor.white

func roundedBar(x: CGFloat, width: CGFloat, height: CGFloat, alpha: CGFloat) {
    let r = CGRect(x: x, y: cy - height / 2, width: width, height: height)
    let p = NSBezierPath(roundedRect: r, xRadius: width / 2, yRadius: width / 2)
    white.withAlphaComponent(alpha).setFill()
    p.fill()
}

// I-beam caret: vertical stem + top/bottom serifs.
let stemW: CGFloat = 72
let stemH: CGFloat = 408
let caretX: CGFloat = 322
let serifW: CGFloat = 168
let serifH: CGFloat = 40

white.setFill()
NSBezierPath(roundedRect: CGRect(x: caretX - stemW / 2, y: cy - stemH / 2,
                                 width: stemW, height: stemH),
             xRadius: 12, yRadius: 12).fill()
for sy in [cy + stemH / 2 - serifH, cy - stemH / 2] {
    NSBezierPath(roundedRect: CGRect(x: caretX - serifW / 2, y: sy,
                                     width: serifW, height: serifH),
                 xRadius: serifH / 2, yRadius: serifH / 2).fill()
}

// Ghost-text completion: faded word blocks trailing the caret.
let lineH: CGFloat = 150
roundedBar(x: 452, width: 250, height: lineH, alpha: 0.55)
roundedBar(x: 732, width: 142, height: lineH, alpha: 0.32)

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to encode PNG\n".data(using: .utf8)!)
    exit(1)
}
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
