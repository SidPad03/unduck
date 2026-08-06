// Draws the DMG window background: a title and an arrow pointing from the app
// icon toward the Applications folder. Usage: swift make-dmg-bg.swift <out.png>
import AppKit
import Foundation

_ = NSApplication.shared   // give AppKit a context for drawing in a CLI
let W: CGFloat = 600, H: CGFloat = 400
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "bg.png"

let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocus()

NSColor(calibratedRed: 0.97, green: 0.975, blue: 0.985, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()

let title = "Drag Unduck into the Applications folder" as NSString
let para = NSMutableParagraphStyle(); para.alignment = .center
title.draw(in: NSRect(x: 20, y: H - 78, width: W - 40, height: 30), withAttributes: [
    .font: NSFont.systemFont(ofSize: 21, weight: .semibold),
    .foregroundColor: NSColor(white: 0.28, alpha: 1),
    .paragraphStyle: para,
])

// Arrow across the middle (icons sit at ~150 and ~450 from the left; y=205 from top).
let y: CGFloat = H - 205
let arrow = NSBezierPath()
arrow.lineWidth = 7; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 252, y: y)); arrow.line(to: NSPoint(x: 348, y: y))
arrow.move(to: NSPoint(x: 348, y: y)); arrow.line(to: NSPoint(x: 330, y: y + 13))
arrow.move(to: NSPoint(x: 348, y: y)); arrow.line(to: NSPoint(x: 330, y: y - 13))
NSColor(white: 0.62, alpha: 1).setStroke()
arrow.stroke()

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to render bg\n".utf8)); exit(1)
}
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
