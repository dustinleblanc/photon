import AppKit

/// Renders the menu bar icon: a donut progress ring around a camera glyph.
///
/// The returned image is a template image, so macOS recolors it to match the
/// menu bar (white in dark mode, black in light). Progress is expressed purely
/// through the alpha channel -- the filled arc is opaque while the remaining
/// track is faint -- which is exactly what a template image can carry.
enum MenuBarIcon {
    /// `fraction` is the library upload progress (0...1).
    static func progress(fraction: Double) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let center = NSPoint(x: size.width / 2, y: size.height / 2)
        let radius: CGFloat = 7.2
        let lineWidth: CGFloat = 1.7

        // Faint full ring = the track (how much is left to do).
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        NSColor(white: 0, alpha: 0.35).setStroke()
        track.stroke()

        // Opaque arc = progress, drawn clockwise from 12 o'clock.
        let f = min(1, max(0, fraction))
        if f > 0 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius,
                          startAngle: 90, endAngle: 90 - f * 360, clockwise: true)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            NSColor(white: 0, alpha: 1).setStroke()
            arc.stroke()
        }

        // Camera glyph, centered inside the ring.
        if let symbol = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: "camera"),
           let glyph = symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 7, weight: .medium)) {
            let gs = glyph.size
            glyph.draw(in: CGRect(x: center.x - gs.width / 2,
                                  y: center.y - gs.height / 2,
                                  width: gs.width, height: gs.height))
        }

        image.isTemplate = true
        return image
    }
}
