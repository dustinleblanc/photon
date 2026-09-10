import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Renders the Photon Migrate app icon: a Proton-branded gradient tile
// (violet #6D4AFF -> blue #4B9FFF) with a white photo glyph.
//
// Usage: swift make_app_icon.swift <output-1024.png>
// Outputs a 1024x1024 PNG sized for AppIcon.iconset -> iconutil -> .icns.

let size: CGFloat = 1024

func cgColor(_ hex: UInt32) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255
    let g = CGFloat((hex >> 8) & 0xFF) / 255
    let b = CGFloat(hex & 0xFF) / 255
    return CGColor(red: r, green: g, blue: b, alpha: 1)
}

guard let ctx = CGContext(
    data: nil,
    width: Int(size), height: Int(size),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("no context") }

// Backdrop tile: rounded rect clipped, so corners are transparent.
let tile = CGRect(x: 0, y: 0, width: size, height: size)
let cornerRadius: CGFloat = 185
ctx.addPath(CGPath(roundedRect: tile, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
ctx.saveGState()
ctx.clip()

// Linear gradient, top-left violet to bottom-right blue.
let colors = [cgColor(0x6D4AFF), cgColor(0x4B9FFF)] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: size),       // CoreGraphics: vertical axis is bottom-up
    end: CGPoint(x: size, y: 0),
    options: []
)

// Subtle top-left sheen.
let sheen = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.20),
             CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(
    sheen,
    startCenter: CGPoint(x: 340, y: 700), startRadius: 0,
    endCenter: CGPoint(x: 340, y: 700), endRadius: 760,
    options: []
)

// Photo glyph, white.
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

// Frame.
let frame = CGRect(x: 230, y: 230, width: 564, height: 564)
ctx.setStrokeColor(white)
ctx.setLineWidth(72)
ctx.setLineJoin(.round)
ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 46, cornerHeight: 46, transform: nil))
ctx.strokePath()

// Sun (top-left inside the frame).
ctx.setFillColor(white)
ctx.fillEllipse(in: CGRect(x: 304, y: 484, width: 112, height: 112))

// Mountains. Back peak first, then front peak overlapping.
func triangle(_ pts: (CGPoint, CGPoint, CGPoint)) {
    ctx.beginPath()
    ctx.move(to: pts.0)
    ctx.addLine(to: pts.1)
    ctx.addLine(to: pts.2)
    ctx.closePath()
    ctx.fillPath()
}

triangle((CGPoint(x: 310, y: 715), CGPoint(x: 430, y: 565), CGPoint(x: 550, y: 715)))
triangle((CGPoint(x: 448, y: 715), CGPoint(x: 585, y: 528), CGPoint(x: 722, y: 715)))

ctx.restoreGState()

// Write PNG.
let outURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let image = ctx.makeImage() else { fatalError("no image") }
guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("no dest")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("write failed") }
print("wrote \(outURL.path)")