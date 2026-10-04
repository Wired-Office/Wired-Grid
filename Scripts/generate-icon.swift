#!/usr/bin/env swift
// Renders the Wired Grid app icon into the asset catalog.
// Usage: swift Scripts/generate-icon.swift [output-directory]
//
// Design (matches LBrowser and Wired Paper): a white squircle, a dot-matrix
// spreadsheet — darker header row and gridlines, softly lit cells — and a
// single green dot.

import AppKit

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "WiredGrid/Resources/Assets.xcassets/AppIcon.appiconset")

let accent = CGColor(srgbRed: 0.118, green: 0.604, blue: 0.373, alpha: 1)

/// Ink density (0…1) for the dot at lattice column `c` of `columns`, row `r` of `rows`.
func density(_ c: Int, _ r: Int, _ columns: Int, _ rows: Int) -> Double {
    let x = Double(c) / Double(columns - 1), y = Double(r) / Double(rows - 1)
    // Light falls from the top left, like LBrowser's cloud.
    let light = 0.5 - 0.3 * y - 0.2 * x
    let gridColumns: Set<Int> = [0, 4, 11, 18, columns - 1]
    let isGridRow = r == rows - 1 || (r >= 3 && (r - 3) % 3 == 0)
    if r < 3 { return 0.78 + light * 0.4 }                        // header row
    if gridColumns.contains(c) || isGridRow { return 0.55 + light * 0.5 }   // gridlines
    if c < 4 { return 0.22 + light * 0.3 }                         // row-number column
    return 0.02 + light * 0.18                                     // cells
}

func drawIcon(in ctx: CGContext, size: CGFloat) {
    ctx.scaleBy(x: size / 1024, y: size / 1024)

    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.addPath(tile)
    ctx.setFillColor(CGColor(gray: 0.996, alpha: 1))
    ctx.fillPath()
    ctx.addPath(tile)
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.10))
    ctx.setLineWidth(4)
    ctx.strokePath()

    // The dot matrix: square dots sized and shaded by density, on an exact lattice.
    let columns = 26, rows = 16
    let pitch = 23.0
    let width = pitch * Double(columns - 1), height = pitch * Double(rows - 1)
    let originX = (1024 - width) / 2, top = 1024 - (1024 - height) / 2 - 40
    for r in 0..<rows {
        for c in 0..<columns {
            let h = density(c, r, columns, rows)
            guard h > 0 else { continue }
            let s = pitch * 0.66 * (0.25 + 0.75 * h)
            ctx.setFillColor(CGColor(srgbRed: 0.039, green: 0.039, blue: 0.043, alpha: 0.2 + 0.8 * h))
            ctx.fill(CGRect(x: originX + Double(c) * pitch - s / 2, y: top - Double(r) * pitch - s / 2, width: s, height: s))
        }
    }

    ctx.setFillColor(accent)
    ctx.fillEllipse(in: CGRect(x: 690, y: 700, width: 80, height: 80))
}

func renderPNG(pixels: Int) -> Data {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    drawIcon(in: ctx, size: CGFloat(pixels))
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

struct Entry { let size: Int; let scale: Int }
let entries = [16, 32, 128, 256, 512].flatMap { [Entry(size: $0, scale: 1), Entry(size: $0, scale: 2)] }

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
var images: [[String: String]] = []
for entry in entries {
    let name = "icon_\(entry.size)x\(entry.size)\(entry.scale == 2 ? "@2x" : "").png"
    try renderPNG(pixels: entry.size * entry.scale).write(to: outputDirectory.appendingPathComponent(name))
    images.append(["filename": name, "idiom": "mac", "scale": "\(entry.scale)x", "size": "\(entry.size)x\(entry.size)"])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: outputDirectory.appendingPathComponent("Contents.json"))
print("Wrote \(entries.count) icon images to \(outputDirectory.path)")
