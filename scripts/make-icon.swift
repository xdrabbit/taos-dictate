// Renders the app icon:  swift scripts/make-icon.swift App/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import AppKit
// TAOS ring logo as an iOS app icon: 1024×1024, opaque, square (iOS applies its own mask).
let S: CGFloat = 1024
let bg = NSColor(srgbRed: 0x18/255, green: 0x15/255, blue: 0x12/255, alpha: 1)
let gold = NSColor(srgbRed: 0xE1/255, green: 0xAA/255, blue: 0x59/255, alpha: 1)
let white = NSColor(srgbRed: 0xF7/255, green: 0xF7/255, blue: 0xF6/255, alpha: 1)

// Opaque RGB (alpha byte skipped): App Store icons must not have transparency.
let cg = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
bg.setFill(); NSRect(x: 0, y: 0, width: S, height: S).fill()

// Gold ring
let r: CGFloat = 400, lw: CGFloat = 16
let ring = NSBezierPath(ovalIn: NSRect(x: S/2 - r, y: S/2 - r, width: 2*r, height: 2*r))
ring.lineWidth = lw; gold.setStroke(); ring.stroke()

func draw(_ text: String, font: NSFont, color: NSColor, kern: CGFloat, centerY: CGFloat) {
    let a = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .kern: kern])
    let size = a.size()
    // Trailing kern adds space after the last glyph; shift to keep optical centre.
    a.draw(at: NSPoint(x: (S - size.width + kern) / 2, y: centerY - size.height / 2))
}
draw("TAOS", font: .systemFont(ofSize: 212, weight: .heavy), color: white, kern: 22, centerY: S/2 + 40)
draw("translation · traducción", font: .systemFont(ofSize: 46, weight: .semibold), color: gold, kern: 1, centerY: S/2 - 120)

NSGraphicsContext.restoreGraphicsState()
let rep = NSBitmapImageRep(cgImage: cg.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
