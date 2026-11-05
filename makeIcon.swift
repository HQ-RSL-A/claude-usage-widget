#!/usr/bin/env swift
// Run: swift makeIcon.swift [outputDir]
// Draws the app icon and writes every macOS size into ClaudeUsageWidget/Assets.xcassets/AppIcon.appiconset
// (or into outputDir, which is how to try a change without touching the asset catalog).
//
// Run it from any folder. Without an outputDir it finds the asset catalog from where this script sits, so keep the
// script in the project folder, beside ClaudeUsageWidget/. If the catalog is not there it stops and says so.
//
// The icon is a "reserve tank": a glass orb with RSL/A-blue liquid about two
// thirds full, on an ink squircle that sits on the macOS icon grid (an 824 pt
// body on a 1024 pt canvas). Every size is a fresh vector render, never a downscale.
// All geometry is in a 1024-unit design space and scaled to the size being drawn.
//
// Small sizes get a few optical adjustments so the orb still reads as a filled orb at
// 16 px: the body edge snaps to whole pixels, the rim never gets thinner than a pixel
// (and is brighter), and the gloss, crest line and edge light fade out below 128 px.

import CoreGraphics
import Foundation
import ImageIO

// MARK: - Helpers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

func white(_ alpha: CGFloat) -> CGColor { CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha) }

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
}

func radians(_ degrees: CGFloat) -> CGFloat { degrees * .pi / 180 }

/// A rounded rectangle with continuous corners, the curve Apple's icon mask uses:
/// curvature eases in and out instead of jumping from straight to circular.
/// `smoothing` 0 gives plain circular corners, 0.6 is the iOS and macOS look.
func continuousRoundedRect(_ rect: CGRect, radius r: CGFloat, smoothing: CGFloat = 0.6) -> CGPath {
    var smooth = smoothing
    var p = (1 + smooth) * r                           // where the curve starts, from the corner along each edge
    let budget = min(rect.width, rect.height) / 2
    if p > budget { smooth = max(0, budget / r - 1); p = budget }

    let arcDegrees = 90 * (1 - smooth)                 // the part of the corner that is a true circle
    let arcLen = sin(radians(arcDegrees / 2)) * r * 2.0.squareRoot()
    let beta = 45 * smooth                             // heading of the ease-in curve where it meets the circle
    let c = r * tan(radians((90 - arcDegrees) / 4)) * cos(radians(beta))
    let d = c * tan(radians(beta))
    let b = (p - arcLen - c - d) / 3
    let a = 2 * b
    let k = 4.0 / 3.0 * tan(radians(arcDegrees) / 4) * r   // handle length: one cubic is exact enough for the circular part

    // Corners walked clockwise from the top edge: the corner point, the direction of
    // travel arriving at it, and the direction leaving it.
    let corners: [(CGPoint, CGPoint, CGPoint)] = [
        (CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: -1)),
        (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: 0, y: -1), CGPoint(x: -1, y: 0)),
        (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: -1, y: 0), CGPoint(x: 0, y: 1)),
        (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 0)),
    ]

    let path = CGMutablePath()
    path.move(to: CGPoint(x: rect.minX + p, y: rect.maxY))
    for (corner, t1, t2) in corners {
        // Local frame of a corner: x runs along the edge arriving at it, y along the edge leaving it.
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: corner.x + (x - p) * t1.x + y * t2.x, y: corner.y + (x - p) * t1.y + y * t2.y)
        }
        let arcStart = (x: a + b + c, y: d)
        let arcEnd = (x: arcStart.x + arcLen, y: arcStart.y + arcLen)
        path.addLine(to: pt(0, 0))
        path.addCurve(to: pt(arcStart.x, arcStart.y), control1: pt(a, 0), control2: pt(a + b, 0))
        path.addCurve(to: pt(arcEnd.x, arcEnd.y),
                      control1: pt(arcStart.x + k * cos(radians(beta)), arcStart.y + k * sin(radians(beta))),
                      control2: pt(arcEnd.x - k * cos(radians(beta + arcDegrees)), arcEnd.y - k * sin(radians(beta + arcDegrees))))
        path.addCurve(to: pt(p, p),
                      control1: pt(arcEnd.x + d, arcEnd.y + c),
                      control2: pt(arcEnd.x + d, arcEnd.y + b + c))
    }
    path.closeSubpath()
    return path
}

// MARK: - Drawing

func drawIcon(in ctx: CGContext, pixels: Int) {
    let px = CGFloat(pixels)
    let unit = px / 1024                                   // device pixels per design unit
    // How much fine detail this size can carry: none at 32 px and below, all of it from 128 px up.
    let detail = max(0, min(1, (px - 32) / 96))

    ctx.saveGState()
    ctx.scaleBy(x: unit, y: unit)

    // Body: an ink squircle on the macOS icon grid, 824 of 1024 across. Its edge snaps to a whole
    // even number of pixels so it stays crisp at small sizes (only 128 px and below actually move).
    let bodyPixels = 2 * ceil(px * 824 / 1024 / 2)
    let bodySide = bodyPixels / unit
    let body = CGRect(x: (1024 - bodySide) / 2, y: (1024 - bodySide) / 2, width: bodySide, height: bodySide)
    let fit = bodySide / 824                               // everything on the body scales with it
    let bodyPath = continuousRoundedRect(body, radius: 185 * fit)

    ctx.saveGState()
    // A shadow's offset and blur are in device units, so the scale above does not apply to them.
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * unit), blur: 24 * unit, color: CGColor(gray: 0, alpha: 0.35))
    ctx.setFillColor(rgb(0x0A0A0A))
    ctx.addPath(bodyPath)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0x2A2A2F)), (1, rgb(0x0A0A0A))]),
                           start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])

    // The edge of the body: the inner half of a thin stroke, lit along the top and a faint keyline
    // below, so the dark body keeps its outline on a dark wallpaper.
    ctx.addPath(bodyPath)
    ctx.setLineWidth(8 * fit)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, white(0.16 * detail)), (0.45, white(0.05 * detail)), (1, white(0.05 * detail))]),
                           start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
    ctx.restoreGState()

    // Orb: a dark glass circle, radius 300, at the center.
    ctx.translateBy(x: 512, y: 512)
    ctx.scaleBy(x: fit, y: fit)
    ctx.translateBy(x: -512, y: -512)

    let radius: CGFloat = 300
    let rimWidth = max(10, 1.1 / (unit * fit))             // 10 units, but never thinner than a pixel
    let orbRect = CGRect(x: 512 - radius, y: 512 - radius, width: 2 * radius, height: 2 * radius)
    let orb = CGPath(ellipseIn: orbRect, transform: nil)

    ctx.setFillColor(rgb(0x0F1A2E))
    ctx.addPath(orb)
    ctx.fillPath()

    // Liquid: the bottom 66% of the orb, topped by a gentle sine wave (2 periods across the orb, amplitude 14).
    let level = orbRect.minY + orbRect.height * 0.66
    let amplitude: CGFloat = 14
    func waveY(_ x: CGFloat) -> CGFloat {
        level + amplitude * sin(2 * .pi * 2 * (x - orbRect.minX) / orbRect.width)
    }
    let waveStart = orbRect.minX - 4, waveEnd = orbRect.maxX + 4   // overshoot the orb, the clip trims it
    func wave(into path: CGMutablePath) {
        path.move(to: CGPoint(x: waveStart, y: waveY(waveStart)))
        var x = waveStart
        while x < waveEnd {
            x = min(x + 2, waveEnd)
            path.addLine(to: CGPoint(x: x, y: waveY(x)))
        }
    }

    ctx.saveGState()
    ctx.addPath(orb)
    ctx.clip()

    let liquid = CGMutablePath()
    wave(into: liquid)
    liquid.addLine(to: CGPoint(x: waveEnd, y: 0))
    liquid.addLine(to: CGPoint(x: waveStart, y: 0))
    liquid.closeSubpath()
    ctx.saveGState()
    ctx.addPath(liquid)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0x3B82F6)), (1, rgb(0x0059C2))]),
                           start: CGPoint(x: 512, y: level + amplitude), end: CGPoint(x: 512, y: orbRect.minY), options: [])
    ctx.restoreGState()

    // A lighter crest line along the wave top, kept inside the rim. Filled as an outline, so it blends once.
    ctx.addEllipse(in: orbRect.insetBy(dx: rimWidth, dy: rimWidth))
    ctx.clip()
    let crest = CGMutablePath()
    wave(into: crest)
    ctx.addPath(crest)
    ctx.setLineWidth(6)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.setFillColor(rgb(0x7DB3FF, alpha: 0.6 * detail))
    ctx.fillPath()
    ctx.restoreGState()

    // Rim: a thin white edge, drawn inside the glass.
    ctx.setStrokeColor(white(0.22 + 0.22 * (1 - detail)))
    ctx.setLineWidth(rimWidth)
    ctx.strokeEllipse(in: orbRect.insetBy(dx: rimWidth / 2, dy: rimWidth / 2))

    // Specular highlight: an ellipse in the top-left of the orb, brightest along its upper edge.
    if detail > 0 {
        ctx.saveGState()
        ctx.addPath(orb)
        ctx.clip()
        ctx.translateBy(x: 512 - 107, y: 512 + 188)
        ctx.rotate(by: radians(38))
        ctx.addEllipse(in: CGRect(x: -118, y: -52, width: 236, height: 104))
        ctx.clip()
        ctx.drawLinearGradient(gradient([(0, white(0.26 * detail)), (1, white(0.06 * detail))]),
                               start: CGPoint(x: 0, y: 52), end: CGPoint(x: 0, y: -52), options: [])
        ctx.restoreGState()
    }

    ctx.restoreGState()
}

// MARK: - Output

func render(pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    drawIcon(in: ctx, pixels: pixels)
    return ctx.makeImage()!
}

func savePNG(_ image: CGImage, to path: String) {
    guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else {
        print("✗ \(path): cannot create the file")
        exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        print("✗ \(path): cannot write the PNG")
        exit(1)
    }
    print("✓ \(path)")
}

// MARK: - Generate

/// Where the PNGs go: the folder given, or else the project's own asset catalog, found from this script's location
/// (the folder it is run from does not matter).
func outputFolder() -> String {
    if CommandLine.arguments.count > 1 { return CommandLine.arguments[1] }
    let projectFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let catalog = projectFolder.appendingPathComponent("ClaudeUsageWidget/Assets.xcassets")
    var isFolder: ObjCBool = false
    guard FileManager.default.fileExists(atPath: catalog.path, isDirectory: &isFolder), isFolder.boolValue else {
        print("✗ No asset catalog at \(catalog.path)")
        print("  makeIcon.swift finds ClaudeUsageWidget/Assets.xcassets from where the script sits, so keep it in the project folder.")
        print("  To write the PNGs somewhere else: swift makeIcon.swift <outputDir>")
        exit(1)
    }
    return catalog.appendingPathComponent("AppIcon.appiconset").path
}

let outDir = outputFolder()
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let sizes: [(name: String, points: Int, scale: Int)] = [
    ("icon_16x16",     16,  1),
    ("icon_16x16@2x",  16,  2),
    ("icon_32x32",     32,  1),
    ("icon_32x32@2x",  32,  2),
    ("icon_128x128",   128, 1),
    ("icon_128x128@2x",128, 2),
    ("icon_256x256",   256, 1),
    ("icon_256x256@2x",256, 2),
    ("icon_512x512",   512, 1),
    ("icon_512x512@2x",512, 2),
]

for entry in sizes {
    savePNG(render(pixels: entry.points * entry.scale), to: "\(outDir)/\(entry.name).png")
}

// MARK: - Contents.json

let json = """
{
  "images" : [
    { "filename" : "icon_16x16.png",      "idiom" : "mac", "scale" : "1x", "size" : "16x16"   },
    { "filename" : "icon_16x16@2x.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16"   },
    { "filename" : "icon_32x32.png",      "idiom" : "mac", "scale" : "1x", "size" : "32x32"   },
    { "filename" : "icon_32x32@2x.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32"   },
    { "filename" : "icon_128x128.png",    "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png",    "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png",    "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""

try! json.write(toFile: "\(outDir)/Contents.json", atomically: true, encoding: .utf8)
print("✓ Contents.json")
print("Done. Open Xcode and the AppIcon should appear automatically.")
