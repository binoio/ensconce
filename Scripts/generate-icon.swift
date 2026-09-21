#!/usr/bin/env swift
//
// Draws the Ensconce app icon: an app window slipped most of the way into a
// pocket, on a steel-blue squircle. Writes Resources/AppIcon.icns and
// docs/icon.png. Everything is vector, rendered per size, so the 16px glyph
// stays crisp instead of being a blurred downscale.
//
//   swift Scripts/generate-icon.swift

import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Ensconce.iconset")
let icns = root.appendingPathComponent("Resources/AppIcon.icns")
let webIcon = root.appendingPathComponent("docs/icon.png")

// MARK: - Palette (matches the product page and the bino.io tile accent)

let bgTop = NSColor(srgbRed: 0.24, green: 0.33, blue: 0.47, alpha: 1)      // #3D5478
let bgBottom = NSColor(srgbRed: 0.13, green: 0.19, blue: 0.30, alpha: 1)   // #21304C
let pocket = NSColor(srgbRed: 0.09, green: 0.12, blue: 0.20, alpha: 1)     // #171F33
let pocketLip = NSColor(srgbRed: 0.36, green: 0.48, blue: 0.62, alpha: 1)  // #5C7A99 (accent)
let windowBody = NSColor(srgbRed: 0.96, green: 0.97, blue: 0.98, alpha: 1)
let windowBar = NSColor(srgbRed: 0.87, green: 0.89, blue: 0.92, alpha: 1)
let lights = [
    NSColor(srgbRed: 1.00, green: 0.37, blue: 0.34, alpha: 1),
    NSColor(srgbRed: 1.00, green: 0.74, blue: 0.18, alpha: 1),
    NSColor(srgbRed: 0.16, green: 0.78, blue: 0.25, alpha: 1),
]

// MARK: - Drawing

func draw(size px: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: px, height: px))
    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high

    // Full-bleed squircle. macOS masks the Dock tile itself, but Tahoe and
    // later expect the artwork to fill the shape rather than float inside it.
    let frame = NSRect(x: 0, y: 0, width: px, height: px)
    let squircle = NSBezierPath(roundedRect: frame, xRadius: px * 0.2237, yRadius: px * 0.2237)
    NSGradient(starting: bgTop, ending: bgBottom)!.draw(in: squircle, angle: -90)

    // The window: centred, its lower third slipped behind the pocket.
    let winW = px * 0.56
    let winH = px * 0.50
    let winX = (px - winW) / 2
    let winY = px * 0.30
    let winRadius = px * 0.045
    let window = NSRect(x: winX, y: winY, width: winW, height: winH)

    // Soft drop shadow so the window reads as a separate object.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = px * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -px * 0.012)
    shadow.set()
    windowBody.setFill()
    NSBezierPath(roundedRect: window, xRadius: winRadius, yRadius: winRadius).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Title bar: clip to the window's rounded top, fill a strip.
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: window, xRadius: winRadius, yRadius: winRadius).addClip()
    let barH = px * 0.10
    windowBar.setFill()
    NSRect(x: winX, y: winY + winH - barH, width: winW, height: barH).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Traffic lights. Dropped below 32px where they would be sub-pixel smears.
    if px >= 32 {
        let d = px * 0.045
        let gap = px * 0.028
        var x = winX + px * 0.045
        let y = winY + winH - barH / 2 - d / 2
        for color in lights {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: d, height: d)).fill()
            x += d + gap
        }
    }

    // The pocket: a wide, low rounded slab in front of the window's lower part,
    // with a lit lip along its top edge so the overlap is unmistakable.
    let pocketH = px * 0.30
    let pocketW = px * 0.72
    let pocketX = (px - pocketW) / 2
    let pocketY = px * 0.14
    let pocketRect = NSRect(x: pocketX, y: pocketY, width: pocketW, height: pocketH)
    let pocketRadius = px * 0.06

    NSGraphicsContext.saveGraphicsState()
    shadow.shadowBlurRadius = px * 0.04
    shadow.shadowOffset = NSSize(width: 0, height: -px * 0.02)
    shadow.set()
    pocket.setFill()
    NSBezierPath(roundedRect: pocketRect, xRadius: pocketRadius, yRadius: pocketRadius).fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: pocketRect, xRadius: pocketRadius, yRadius: pocketRadius).addClip()
    pocketLip.setFill()
    NSRect(x: pocketX, y: pocketY + pocketH - px * 0.022, width: pocketW, height: px * 0.022).fill()
    NSGraphicsContext.restoreGraphicsState()

    image.unlockFocus()
    return image
}

func png(_ image: NSImage) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(image.size.width), pixelsHigh: Int(image.size.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = image.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: image.size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// MARK: - Output

try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try! png(draw(size: CGFloat(points * scale))).write(to: iconset.appendingPathComponent(name))
}

try! FileManager.default.createDirectory(at: icns.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}

try! FileManager.default.createDirectory(at: webIcon.deletingLastPathComponent(), withIntermediateDirectories: true)
try! png(draw(size: 512)).write(to: webIcon)

print("Wrote \(icns.path)")
print("Wrote \(webIcon.path)")
