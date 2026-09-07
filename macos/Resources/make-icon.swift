// Generates the app icon from source: the repository keeps no binary image files.
// build.sh compiles and invokes it:  make-icon <output.iconset directory>
//
// Design: a deep navy rounded square (macOS corner ratio) carrying two opposing arrows — the
// white one going out, the mint one coming back. That is the whole app in one picture: two
// devices, both directions, nothing else. The drawing is the same one as the Android launcher
// icon (android/app/src/main/res/drawable/ic_launcher_foreground.xml), expressed in the same
// 108-unit coordinate space so the two icons stay identical.
//
// Every point lies inside the centred radius-33 circle, the safe zone of an Android adaptive
// icon, so no launcher mask can clip it and the same geometry survives both platforms.
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

/// In a headless process (no NSApplication) the only reliable way is drawing into an explicit
/// bitmap context.
func bitmap(_ px: Int, draw: (NSRect) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// A rounded rectangle in the 108-unit, y-down design space of the Android drawable.
func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}

/// A filled arrow as ONE closed outline: rounded tail, straight shaft, triangular head.
///
/// Drawn as a single contour rather than a pill plus a triangle. Two overlapping subpaths render
/// the cap's edge as a seam through the head at some sizes, whichever winding rule is used, and
/// the shadow below picks that seam up as a line.
///
/// `tailX` is the flat end, `tipX` the point; the shaft is 10 units tall and the head 26, which is
/// what keeps the pair readable at 16 px.
func arrow(tailX: CGFloat, tipX: CGFloat, midY: CGFloat) -> NSBezierPath {
    let facingRight = tipX > tailX
    let shaft: CGFloat = 5                      // half the shaft height, and the tail's radius
    let head: CGFloat = 13                      // half the head height
    let baseX = facingRight ? tipX - 17 : tipX + 17
    let capX = facingRight ? tailX + shaft : tailX - shaft

    let path = NSBezierPath()
    path.move(to: NSPoint(x: capX, y: midY - shaft))
    path.line(to: NSPoint(x: baseX, y: midY - shaft))
    path.line(to: NSPoint(x: baseX, y: midY - head))
    path.line(to: NSPoint(x: tipX, y: midY))
    path.line(to: NSPoint(x: baseX, y: midY + head))
    path.line(to: NSPoint(x: baseX, y: midY + shaft))
    path.line(to: NSPoint(x: capX, y: midY + shaft))
    // The rounded tail. A semicircle is symmetric, so the flipped design space does not care
    // which way round it is drawn.
    path.appendArc(withCenter: NSPoint(x: capX, y: midY), radius: shaft,
                   startAngle: facingRight ? 90 : 270,
                   endAngle: facingRight ? 270 : 90)
    path.close()
    return path
}

/// Out to the phone.
func outbound() -> NSBezierPath {
    arrow(tailX: 29, tipX: 79, midY: 42)
}

/// Back to the Mac. The second colour is what makes the pair read as two directions rather than
/// as one double-headed arrow.
func inbound() -> NSBezierPath {
    arrow(tailX: 79, tipX: 29, midY: 66)
}

let mint = NSColor(calibratedRed: 0.455, green: 0.894, blue: 0.808, alpha: 1)   // #74E4CE

func render(_ px: Int) -> Data {
    let size = CGFloat(px)
    let rep = bitmap(px) { bounds in
        // macOS icons cover ~80% of the canvas; the remaining margin is the system's standard padding.
        let inset = size * 0.1
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let square = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

        // Same palette as the Android background: #1E3A5F → #0F1D2E, top-left to bottom-right.
        NSGradient(colors: [
            NSColor(calibratedRed: 0.118, green: 0.227, blue: 0.373, alpha: 1),
            NSColor(calibratedRed: 0.059, green: 0.114, blue: 0.180, alpha: 1),
        ])!.draw(in: square, angle: -45)

        // Soft highlight at the top left so the surface does not read as flat. Clipped to the square.
        NSGraphicsContext.saveGraphicsState()
        square.addClip()
        NSGradient(colors: [
            NSColor.white.withAlphaComponent(0.16),
            NSColor.white.withAlphaComponent(0.0),
        ])!.draw(
            fromCenter: NSPoint(x: rect.minX + rect.width * 0.28, y: rect.maxY - rect.height * 0.22),
            radius: 0,
            toCenter: NSPoint(x: rect.minX + rect.width * 0.28, y: rect.maxY - rect.height * 0.22),
            radius: rect.width * 0.75,
            options: []
        )
        NSGraphicsContext.restoreGraphicsState()

        // Thin inner border: keeps the edge visible on dark desktops.
        NSColor.white.withAlphaComponent(0.14).setStroke()
        square.lineWidth = max(1, size * 0.008)
        square.stroke()

        // Map the 108-unit y-down design space onto the square (flip y). The arrows then cover
        // about 46% of the square's width, the proportion macOS icons use for their glyph.
        let scale = rect.width / 108
        var transform = AffineTransform(translationByX: rect.minX, byY: rect.maxY)
        transform.scale(x: scale, y: -scale)

        // Slight shadow: the arrows sit on the surface instead of looking pasted on it.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = size * 0.02
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.008)
        shadow.set()

        for (path, colour) in [(outbound(), NSColor.white), (inbound(), mint)] {
            path.transform(using: transform)
            colour.setFill()
            path.fill()
        }
    }
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("could not produce PNG") }
    return png
}

// The names iconutil expects.
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    try render(px).write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
print("iconset: \(out)")
