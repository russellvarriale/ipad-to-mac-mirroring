// Copyright (c) 2026 Russell Varriale (https://github.com/russellvarriale/ipad-to-mac-mirroring)
// SPDX-License-Identifier: MIT
// Original app icon: rounded rectangles, gradients, and circles drawn below.
// No SF Symbol or third-party image is embedded in the generated artwork.
// Usage: swift scripts/make-icon.swift path/to/AppIcon.iconset
// Then: iconutil -c icns path/to/AppIcon.iconset
import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift make-icon.swift OUTPUT.iconset\n", stderr)
    exit(2)
}
let directory = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
for (size, name) in [(16,"icon_16x16"),(32,"icon_16x16@2x"),(32,"icon_32x32"),(64,"icon_32x32@2x"),(128,"icon_128x128"),(256,"icon_128x128@2x"),(256,"icon_256x256"),(512,"icon_256x256@2x"),(512,"icon_512x512"),(1024,"icon_512x512@2x")] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(size) / 1024
    let transform = AffineTransform(scale: scale)
    (transform as NSAffineTransform).concat()
    let base = NSBezierPath(roundedRect: NSRect(x: 68, y: 68, width: 888, height: 888), xRadius: 202, yRadius: 202)
    NSGradient(starting: NSColor(calibratedRed: 0.24, green: 0.26, blue: 0.62, alpha: 1), ending: NSColor(calibratedRed: 0.07, green: 0.10, blue: 0.23, alpha: 1))!.draw(in: base, angle: -80)
    let tablet = NSBezierPath(roundedRect: NSRect(x: 270, y: 218, width: 484, height: 638), xRadius: 58, yRadius: 58)
    NSColor(calibratedRed: 0.80, green: 0.85, blue: 1.0, alpha: 1).setFill()
    tablet.fill()
    let screen = NSBezierPath(roundedRect: NSRect(x: 293, y: 246, width: 438, height: 580), xRadius: 35, yRadius: 35)
    NSGradient(starting: NSColor(calibratedRed: 0.38, green: 0.67, blue: 1, alpha: 1), ending: NSColor(calibratedRed: 0.33, green: 0.31, blue: 0.75, alpha: 1))!.draw(in: screen, angle: -50)
    NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 504, y: 832, width: 16, height: 16)).fill()
    let window = NSBezierPath(roundedRect: NSRect(x: 436, y: 158, width: 380, height: 266), xRadius: 35, yRadius: 35)
    NSColor(calibratedRed: 0.89, green: 0.95, blue: 1, alpha: 1).setFill()
    window.fill()
    NSColor(calibratedRed: 0.12, green: 0.21, blue: 0.40, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 452, y: 174, width: 348, height: 204), xRadius: 20, yRadius: 20).fill()
    for x in [466, 488, 510] {
        NSColor(calibratedRed: 0.46, green: 0.59, blue: 0.79, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: 392, width: 12, height: 12)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
}
