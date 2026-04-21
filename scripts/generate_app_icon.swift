#!/usr/bin/env swift
//
// Generates projects/infer/Resources/AppIcon.icns using CoreGraphics and the
// macOS `iconutil` tool. Design is a placeholder: indigo -> violet squircle
// with an inference glyph (three input nodes -> one output node).
//
// Run from the repo root:
//     swift scripts/generate_app_icon.swift
//
// Produces:
//     projects/infer/Resources/AppIcon.iconset/  (intermediate)
//     projects/infer/Resources/AppIcon.icns       (shipped)

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

let outDir = "projects/infer/Resources"
let iconsetDir = "\(outDir)/AppIcon.iconset"
let icnsPath = "\(outDir)/AppIcon.icns"

let fm = FileManager.default
try? fm.removeItem(atPath: iconsetDir)
try fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

// (fileName, pixelSize) pairs expected by `iconutil`.
let sizes: [(String, Int)] = [
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

// Draw the icon at an arbitrary pixel size. All positions are computed as
// fractions of `size` so the design scales cleanly from 16pt to 1024pt.
func drawIcon(size: Int) -> CGImage? {
    let s = CGFloat(size)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // Clear.
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0))
    ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

    // Rounded-square mask (macOS squircle-approximation: ~22% corner radius).
    let corner = s * 0.2237
    let rect = CGRect(x: 0, y: 0, width: s, height: s)
    let squirclePath = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.addPath(squirclePath)
    ctx.clip()

    // Diagonal gradient background: deep indigo -> violet.
    let colors = [
        CGColor(red: 0.102, green: 0.106, blue: 0.294, alpha: 1.0),  // #1a1b4b
        CGColor(red: 0.420, green: 0.294, blue: 0.659, alpha: 1.0),  // #6b4ba8
    ] as CFArray
    let stops: [CGFloat] = [0.0, 1.0]
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: stops) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: s),
            end: CGPoint(x: s, y: 0),
            options: []
        )
    }

    // Subtle top highlight for depth.
    let highlight = [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.12),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
    ] as CFArray
    if let g2 = CGGradient(colorsSpace: colorSpace, colors: highlight, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            g2,
            start: CGPoint(x: s * 0.5, y: s),
            end: CGPoint(x: s * 0.5, y: s * 0.5),
            options: []
        )
    }

    // --- Inference glyph ---
    // Three input nodes on the left at y = {0.25, 0.5, 0.75} * s, x = 0.28 * s.
    // One output node on the right at (0.74, 0.5) * s.
    // Edges: lines from each input to the output.

    let inputX = s * 0.28
    let outputX = s * 0.74
    let outputY = s * 0.5
    let inputYs: [CGFloat] = [s * 0.26, s * 0.50, s * 0.74]
    let inputRadius = s * 0.055
    let outputRadius = s * 0.095

    // Edges first (under the nodes).
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
    ctx.setLineWidth(max(1, s * 0.018))
    ctx.setLineCap(.round)
    for y in inputYs {
        ctx.move(to: CGPoint(x: inputX + inputRadius * 0.5, y: y))
        ctx.addLine(to: CGPoint(x: outputX - outputRadius * 0.5, y: outputY))
    }
    ctx.strokePath()

    // Input nodes: solid white with a soft inner shadow effect via stroke ring.
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1.0))
    for y in inputYs {
        let r = CGRect(
            x: inputX - inputRadius,
            y: y - inputRadius,
            width: inputRadius * 2,
            height: inputRadius * 2
        )
        ctx.fillEllipse(in: r)
    }

    // Output node: larger, with a violet inner accent ring so it reads as
    // "the inferred result" rather than just a fourth node.
    let outRect = CGRect(
        x: outputX - outputRadius,
        y: outputY - outputRadius,
        width: outputRadius * 2,
        height: outputRadius * 2
    )
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1.0))
    ctx.fillEllipse(in: outRect)

    let innerAccent = outRect.insetBy(dx: outputRadius * 0.35, dy: outputRadius * 0.35)
    ctx.setFillColor(CGColor(red: 0.420, green: 0.294, blue: 0.659, alpha: 1.0))
    ctx.fillEllipse(in: innerAccent)

    return ctx.makeImage()
}

func writePNG(_ image: CGImage, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw NSError(domain: "icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "CGImageDestination failed"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) {
        throw NSError(domain: "icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "PNG finalize failed"])
    }
}

for (name, px) in sizes {
    guard let img = drawIcon(size: px) else {
        FileHandle.standardError.write(Data("Failed to render \(name)\n".utf8))
        exit(1)
    }
    try writePNG(img, to: "\(iconsetDir)/\(name)")
}

// Invoke iconutil to package the iconset into a .icns.
let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", iconsetDir, "-o", icnsPath]
try task.run()
task.waitUntilExit()
if task.terminationStatus != 0 {
    FileHandle.standardError.write(Data("iconutil failed with status \(task.terminationStatus)\n".utf8))
    exit(Int32(task.terminationStatus))
}

// Leave the iconset directory in place so re-running is idempotent and diff-able.
print("Wrote \(icnsPath)")
