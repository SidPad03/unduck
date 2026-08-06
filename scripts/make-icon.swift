// Renders the Unduck app icon (a rubber duck on a macOS-style rounded tile) to a
// 1024×1024 PNG. Usage: swift scripts/make-icon.swift <output.png>
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
let S = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("no context")
}
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r/255, green: g/255, blue: b/255, alpha: a)
}
func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: cx-rx, y: cy-ry, width: rx*2, height: ry*2), transform: nil)
}

// Rounded tile with the Big Sur-ish grid + a soft drop shadow.
let inset: CGFloat = 96
let tile = CGRect(x: inset, y: inset, width: CGFloat(S) - 2*inset, height: CGFloat(S) - 2*inset)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 190, cornerHeight: 190, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: rgb(0, 0, 0, 0.22))
ctx.addPath(tilePath); ctx.setFillColor(rgb(255, 255, 255)); ctx.fillPath()
ctx.restoreGState()

// Fully white tile (Chrome-style) with a whisper of gradient + a hairline edge
// so it still reads when it sits on a white background.
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let white = CGGradient(colorsSpace: cs, colors: [rgb(255, 255, 255), rgb(248, 248, 250)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(white, start: CGPoint(x: 0, y: CGFloat(S)), end: CGPoint(x: 0, y: 0), options: [])
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath); ctx.setStrokeColor(rgb(230, 230, 233)); ctx.setLineWidth(3); ctx.strokePath()
ctx.restoreGState()

// Duck - layered yellow shapes merge into a rubber duck. Clipped to the tile.
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()

let bodyYellow = rgb(240, 180, 28)   // deeper rubber-ducky yellow
let wingYellow = rgb(216, 150, 18)
let beak = rgb(236, 130, 18)

// body
ctx.addPath(ellipse(500, 452, 232, 176)); ctx.setFillColor(bodyYellow); ctx.fillPath()
// tail (little upswept triangle, left)
ctx.beginPath()
ctx.move(to: CGPoint(x: 300, y: 470))
ctx.addLine(to: CGPoint(x: 208, y: 556))
ctx.addLine(to: CGPoint(x: 322, y: 540))
ctx.closePath(); ctx.setFillColor(bodyYellow); ctx.fillPath()
// head
ctx.addPath(ellipse(662, 588, 158, 158)); ctx.setFillColor(bodyYellow); ctx.fillPath()
// wing
ctx.addPath(ellipse(452, 452, 120, 82)); ctx.setFillColor(wingYellow); ctx.fillPath()
// beak
ctx.beginPath()
ctx.move(to: CGPoint(x: 792, y: 620))
ctx.addLine(to: CGPoint(x: 900, y: 596))
ctx.addLine(to: CGPoint(x: 792, y: 556))
ctx.closePath(); ctx.setFillColor(beak); ctx.fillPath()
// eye
ctx.addPath(ellipse(700, 648, 26, 26)); ctx.setFillColor(rgb(30, 30, 36)); ctx.fillPath()
ctx.addPath(ellipse(709, 657, 9, 9)); ctx.setFillColor(rgb(255, 255, 255)); ctx.fillPath()

ctx.restoreGState()

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil) else {
    fatalError("no image/dest")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("write failed") }
print("wrote \(outPath)")
