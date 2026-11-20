// Generates the original MacAudioOo app icon (an iconset + .icns) with CoreGraphics only.
// Usage: swiftc -O scripts/make-icon.swift -o build/make-icon && build/make-icon Resources
// Design: graphite rounded square, five console-style LED meter columns (green, yellow and orange segments)
// with a raised fader-cap on the centre column.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func render(size: Int) -> CGImage? {
    let s = CGFloat(size)
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.scaleBy(x: s / 1024, y: s / 1024)
    // macOS icon grid: the body occupies ~80 % of the canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: CGColor(gray: 0, alpha: 0.45))
    ctx.addPath(path); ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [CGColor(red: 0.20, green: 0.21, blue: 0.24, alpha: 1),
                                                                                    CGColor(red: 0.07, green: 0.075, blue: 0.09, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    // Meter columns.
    let heights: [Int] = [9, 14, 11, 16, 7]
    let segs = 18, segH: CGFloat = 26, gap: CGFloat = 8, colW: CGFloat = 92, colGap: CGFloat = 38
    let totalW = 5 * colW + 4 * colGap
    let x0 = (1024 - totalW) / 2, y0: CGFloat = 235
    for c in 0..<5 {
        let x = x0 + CGFloat(c) * (colW + colGap)
        ctx.setFillColor(CGColor(gray: 0.04, alpha: 1))
        ctx.addPath(CGPath(roundedRect: CGRect(x: x - 12, y: y0 - 14, width: colW + 24, height: CGFloat(segs) * (segH + gap) + 20), cornerWidth: 26, cornerHeight: 26, transform: nil))
        ctx.fillPath()
        for i in 0..<segs {
            let lit = i < heights[c]
            let color: CGColor
            if i >= 15 { color = CGColor(red: 1, green: 0.5, blue: 0.12, alpha: 1) }
            else if i >= 11 { color = CGColor(red: 0.97, green: 0.82, blue: 0.2, alpha: 1) }
            else { color = CGColor(red: 0.22, green: 0.85, blue: 0.4, alpha: 1) }
            ctx.setFillColor(lit ? color : color.copy(alpha: 0.13)!)
            ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y0 + CGFloat(i) * (segH + gap), width: colW, height: segH), cornerWidth: 8, cornerHeight: 8, transform: nil))
            ctx.fillPath()
        }
    }
    // Fader cap on the centre column.
    let cx = x0 + 2 * (colW + colGap) + colW / 2
    let cap = CGRect(x: cx - 96, y: 470, width: 192, height: 92)
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 14, color: CGColor(gray: 0, alpha: 0.6))
    ctx.addPath(CGPath(roundedRect: cap, cornerWidth: 22, cornerHeight: 22, transform: nil))
    let capG = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [CGColor(gray: 0.62, alpha: 1), CGColor(gray: 0.30, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.saveGState(); ctx.clip(); ctx.drawLinearGradient(capG, start: CGPoint(x: 0, y: cap.maxY), end: CGPoint(x: 0, y: cap.minY), options: []); ctx.restoreGState()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.setFillColor(CGColor(red: 0.22, green: 0.85, blue: 0.4, alpha: 1))
    ctx.fill(CGRect(x: cap.minX + 22, y: cap.midY - 5, width: cap.width - 44, height: 10))
    ctx.restoreGState()
    // Rim light.
    ctx.addPath(path); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12)); ctx.setLineWidth(4); ctx.strokePath()
    return ctx.makeImage()
}

func writePNG(_ img: CGImage, to url: URL) {
    guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        if let img = render(size: px) { writePNG(img, to: iconset.appendingPathComponent("icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png")) }
    }
}
if let big = render(size: 1024) { writePNG(big, to: outDir.appendingPathComponent("AppIcon-1024.png")) }
print("Wrote \(iconset.path)")
