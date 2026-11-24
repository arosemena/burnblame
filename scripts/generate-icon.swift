#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

// Renders a crisp 1024x1024 macOS app icon for BurnBlame and writes all iconset sizes.
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/BurnBlame.iconset"
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func renderIcon(size px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: px, height: px)

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let s = CGFloat(px)

    // macOS Big Sur / Sonoma / Sequoia standard icon inset (~82% canvas)
    let inset = s * 0.088
    let cardRect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let cornerRadius = cardRect.width * 0.225

    let cardPath = CGPath(roundedRect: cardRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Subtle drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.015), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.42).cgColor)
    ctx.addPath(cardPath)
    ctx.setFillColor(NSColor(calibratedRed: 0.09, green: 0.095, blue: 0.12, alpha: 1.0).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Clip inside squircle
    ctx.saveGState()
    ctx.addPath(cardPath)
    ctx.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()

    // Deep dark slate vertical gradient
    let bgColors = [
        CGColor(colorSpace: colorSpace, components: [0.16, 0.16, 0.20, 1.0])!,
        CGColor(colorSpace: colorSpace, components: [0.08, 0.08, 0.11, 1.0])!,
        CGColor(colorSpace: colorSpace, components: [0.05, 0.05, 0.07, 1.0])!
    ] as CFArray
    if let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.55, 1.0]) {
        ctx.drawLinearGradient(
            bgGrad,
            start: CGPoint(x: s * 0.5, y: cardRect.maxY),
            end: CGPoint(x: s * 0.5, y: cardRect.minY),
            options: []
        )
    }

    // Warm radial heat glow behind the flame
    let glowColors = [
        CGColor(colorSpace: colorSpace, components: [1.0, 0.36, 0.12, 0.42])!,
        CGColor(colorSpace: colorSpace, components: [1.0, 0.20, 0.08, 0.12])!,
        CGColor(colorSpace: colorSpace, components: [1.0, 0.15, 0.05, 0.0])!
    ] as CFArray
    if let glow = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 0.48, 1.0]) {
        let center = CGPoint(x: s * 0.5, y: s * 0.44)
        ctx.drawRadialGradient(
            glow,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: cardRect.width * 0.52,
            options: []
        )
    }

    // Draw crisp outer flame silhouette
    let flame = CGMutablePath()
    let cx = s * 0.5
    let cy = s * 0.48
    let fw = cardRect.width * 0.48
    let fh = cardRect.height * 0.62

    flame.move(to: CGPoint(x: cx, y: cy + fh * 0.52)) // top tip
    flame.addCurve(
        to: CGPoint(x: cx + fw * 0.50, y: cy - fh * 0.08),
        control1: CGPoint(x: cx + fw * 0.22, y: cy + fh * 0.30),
        control2: CGPoint(x: cx + fw * 0.54, y: cy + fh * 0.14)
    )
    flame.addCurve(
        to: CGPoint(x: cx, y: cy - fh * 0.48),
        control1: CGPoint(x: cx + fw * 0.48, y: cy - fh * 0.34),
        control2: CGPoint(x: cx + fw * 0.25, y: cy - fh * 0.48)
    )
    flame.addCurve(
        to: CGPoint(x: cx - fw * 0.50, y: cy - fh * 0.08),
        control1: CGPoint(x: cx - fw * 0.25, y: cy - fh * 0.48),
        control2: CGPoint(x: cx - fw * 0.48, y: cy - fh * 0.34)
    )
    flame.addCurve(
        to: CGPoint(x: cx - fw * 0.12, y: cy + fh * 0.18),
        control1: CGPoint(x: cx - fw * 0.53, y: cy + fh * 0.12),
        control2: CGPoint(x: cx - fw * 0.30, y: cy + fh * 0.24)
    )
    flame.addCurve(
        to: CGPoint(x: cx, y: cy + fh * 0.52),
        control1: CGPoint(x: cx - fw * 0.18, y: cy + fh * 0.32),
        control2: CGPoint(x: cx - fw * 0.06, y: cy + fh * 0.44)
    )
    flame.closeSubpath()

    ctx.saveGState()
    ctx.addPath(flame)
    ctx.clip()
    let flameColors = [
        CGColor(colorSpace: colorSpace, components: [1.0, 0.85, 0.24, 1.0])!,
        CGColor(colorSpace: colorSpace, components: [1.0, 0.46, 0.10, 1.0])!,
        CGColor(colorSpace: colorSpace, components: [0.92, 0.16, 0.18, 1.0])!
    ] as CFArray
    if let flameGrad = CGGradient(colorsSpace: colorSpace, colors: flameColors, locations: [0.0, 0.52, 1.0]) {
        ctx.drawLinearGradient(
            flameGrad,
            start: CGPoint(x: cx, y: cy + fh * 0.52),
            end: CGPoint(x: cx, y: cy - fh * 0.48),
            options: []
        )
    }
    ctx.restoreGState()

    // Inner bright core droplet (thermometer bulb / white-gold core)
    let core = CGMutablePath()
    let cw = fw * 0.42
    let ch = fh * 0.44
    let coreY = cy - fh * 0.12
    core.move(to: CGPoint(x: cx, y: coreY + ch * 0.55))
    core.addCurve(
        to: CGPoint(x: cx + cw * 0.5, y: coreY - ch * 0.12),
        control1: CGPoint(x: cx + cw * 0.28, y: coreY + ch * 0.25),
        control2: CGPoint(x: cx + cw * 0.52, y: coreY + ch * 0.08)
    )
    core.addCurve(
        to: CGPoint(x: cx, y: coreY - ch * 0.48),
        control1: CGPoint(x: cx + cw * 0.48, y: coreY - ch * 0.36),
        control2: CGPoint(x: cx + cw * 0.24, y: coreY - ch * 0.48)
    )
    core.addCurve(
        to: CGPoint(x: cx - cw * 0.5, y: coreY - ch * 0.12),
        control1: CGPoint(x: cx - cw * 0.24, y: coreY - ch * 0.48),
        control2: CGPoint(x: cx - cw * 0.48, y: coreY - ch * 0.36)
    )
    core.addCurve(
        to: CGPoint(x: cx, y: coreY + ch * 0.55),
        control1: CGPoint(x: cx - cw * 0.52, y: coreY + ch * 0.08),
        control2: CGPoint(x: cx - cw * 0.28, y: coreY + ch * 0.25)
    )
    core.closeSubpath()

    ctx.saveGState()
    ctx.addPath(core)
    ctx.clip()
    let coreColors = [
        CGColor(colorSpace: colorSpace, components: [1.0, 0.98, 0.82, 0.98])!,
        CGColor(colorSpace: colorSpace, components: [1.0, 0.78, 0.28, 0.95])!
    ] as CFArray
    if let coreGrad = CGGradient(colorsSpace: colorSpace, colors: coreColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            coreGrad,
            start: CGPoint(x: cx, y: coreY + ch * 0.55),
            end: CGPoint(x: cx, y: coreY - ch * 0.48),
            options: []
        )
    }
    ctx.restoreGState()

    // Subtle glass rim highlight
    ctx.addPath(cardPath)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
    ctx.setLineWidth(max(1.0, s * 0.008))
    ctx.strokePath()

    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

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
    ("icon_512x512@2x.png", 1024)
]

for item in sizes {
    let rep = renderIcon(size: item.px)
    let data = rep.representation(using: .png, properties: [:])!
    let path = "\(outDir)/\(item.name)"
    try data.write(to: URL(fileURLWithPath: path))
}
print("Generated iconset at \(outDir)")
