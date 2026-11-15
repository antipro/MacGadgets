import AppKit
import CoreGraphics
import Foundation

struct IconSpec {
    let filename: String
    let pixelSize: Int
}

let specs: [IconSpec] = [
    IconSpec(filename: "icon_16x16.png", pixelSize: 16),
    IconSpec(filename: "icon_16x16@2x.png", pixelSize: 32),
    IconSpec(filename: "icon_32x32.png", pixelSize: 32),
    IconSpec(filename: "icon_32x32@2x.png", pixelSize: 64),
    IconSpec(filename: "icon_128x128.png", pixelSize: 128),
    IconSpec(filename: "icon_128x128@2x.png", pixelSize: 256),
    IconSpec(filename: "icon_256x256.png", pixelSize: 256),
    IconSpec(filename: "icon_256x256@2x.png", pixelSize: 512),
    IconSpec(filename: "icon_512x512.png", pixelSize: 512),
    IconSpec(filename: "icon_512x512@2x.png", pixelSize: 1024)
]

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) -> NSColor {
    NSColor(srgbRed: r / 255.0, green: g / 255.0, blue: b / 255.0, alpha: a)
}

func drawSymbol(
    _ name: String,
    in rect: NSRect,
    pointSize: CGFloat,
    weight: NSFont.Weight,
    tint: NSColor
) {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else {
        return
    }

    let tinted = NSImage(size: base.size)
    tinted.lockFocus()
    tint.set()
    let bounds = NSRect(origin: .zero, size: base.size)
    base.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1.0)
    bounds.fill(using: .sourceAtop)
    tinted.unlockFocus()

    let aspect = base.size.width / max(base.size.height, 1)
    var drawSize = rect.size
    if rect.width / rect.height > aspect {
        drawSize.width = rect.height * aspect
    } else {
        drawSize.height = rect.width / aspect
    }

    let drawRect = NSRect(
        x: rect.midX - drawSize.width / 2,
        y: rect.midY - drawSize.height / 2,
        width: drawSize.width,
        height: drawSize.height
    )
    tinted.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
}

func renderMasterIcon(size: Int = 1024) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    let scale = CGFloat(size) / 1024.0
    cg.scaleBy(x: scale, y: scale)

    // macOS HIG squircle geometry (824x824 centered on 1024x1024)
    let squircleRect = NSRect(x: 100, y: 100, width: 824, height: 824)
    let cornerRadius: CGFloat = 186
    let squirclePath = NSBezierPath(roundedRect: squircleRect, xRadius: cornerRadius, yRadius: cornerRadius)

    // Outer drop shadow
    cg.saveGState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.38)
    shadow.shadowOffset = NSSize(width: 0, height: -18)
    shadow.shadowBlurRadius = 32
    shadow.set()
    color(24, 30, 48).setFill()
    squirclePath.fill()
    cg.restoreGState()

    // Clip to squircle for internal layers
    cg.saveGState()
    squirclePath.addClip()

    // Deep slate-indigo gradient backdrop
    let bgGradient = NSGradient(colors: [
        color(40, 49, 76),
        color(19, 23, 38)
    ])!
    bgGradient.draw(in: squircleRect, angle: -90)

    // Subtle ambient glows inside the squircle
    if let amberGlow = NSGradient(colors: [
        color(255, 159, 10, 0.20),
        color(255, 159, 10, 0.0)
    ]) {
        amberGlow.draw(
            fromCenter: NSPoint(x: 340, y: 690),
            radius: 20,
            toCenter: NSPoint(x: 340, y: 690),
            radius: 360,
            options: []
        )
    }
    if let blueGlow = NSGradient(colors: [
        color(10, 132, 255, 0.22),
        color(10, 132, 255, 0.0)
    ]) {
        blueGlow.draw(
            fromCenter: NSPoint(x: 680, y: 310),
            radius: 20,
            toCenter: NSPoint(x: 680, y: 310),
            radius: 380,
            options: []
        )
    }

    // Card 1 (Top): Keep Awake (warm amber-orange Control Center pill)
    let topCardRect = NSRect(x: 204, y: 546, width: 616, height: 244)
    let topCardPath = NSBezierPath(roundedRect: topCardRect, xRadius: 68, yRadius: 68)
    NSGradient(colors: [
        color(255, 179, 64),
        color(255, 118, 12)
    ])!.draw(in: topCardPath, angle: -90)

    // Top card specular rim
    NSColor.white.withAlphaComponent(0.32).setStroke()
    topCardPath.lineWidth = 3
    topCardPath.stroke()

    // Left icon badge in Top card
    let topCircleRect = NSRect(x: 244, y: 584, width: 168, height: 168)
    NSColor.white.withAlphaComponent(0.24).setFill()
    NSBezierPath(ovalIn: topCircleRect).fill()
    drawSymbol(
        "cup.and.saucer.fill",
        in: topCircleRect.insetBy(dx: 34, dy: 34),
        pointSize: 88,
        weight: .semibold,
        tint: .white
    )

    // Right active toggle indicator in Top card
    let topSwitchRect = NSRect(x: 520, y: 620, width: 244, height: 96)
    NSColor.white.withAlphaComponent(0.28).setFill()
    NSBezierPath(roundedRect: topSwitchRect, xRadius: 48, yRadius: 48).fill()
    cg.saveGState()
    let knobShadow = NSShadow()
    knobShadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    knobShadow.shadowOffset = NSSize(width: 0, height: -4)
    knobShadow.shadowBlurRadius = 10
    knobShadow.set()
    let topKnobRect = NSRect(x: 678, y: 630, width: 76, height: 76)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: topKnobRect).fill()
    cg.restoreGState()

    // Card 2 (Bottom): Scroll Reverser (frosted glass + Apple blue tile)
    let bottomCardRect = NSRect(x: 204, y: 234, width: 616, height: 244)
    let bottomCardPath = NSBezierPath(roundedRect: bottomCardRect, xRadius: 68, yRadius: 68)
    NSGradient(colors: [
        color(64, 76, 112, 0.88),
        color(42, 50, 78, 0.92)
    ])!.draw(in: bottomCardPath, angle: -90)

    NSColor.white.withAlphaComponent(0.20).setStroke()
    bottomCardPath.lineWidth = 3
    bottomCardPath.stroke()

    // Left blue circle in Bottom card
    let bottomCircleRect = NSRect(x: 244, y: 272, width: 168, height: 168)
    let bottomCirclePath = NSBezierPath(ovalIn: bottomCircleRect)
    NSGradient(colors: [
        color(56, 168, 255),
        color(10, 122, 255)
    ])!.draw(in: bottomCirclePath, angle: -90)
    drawSymbol(
        "arrow.up.arrow.down",
        in: bottomCircleRect.insetBy(dx: 36, dy: 36),
        pointSize: 84,
        weight: .bold,
        tint: .white
    )

    // Right active toggle indicator in Bottom card
    let bottomSwitchRect = NSRect(x: 520, y: 308, width: 244, height: 96)
    color(10, 132, 255, 0.52).setFill()
    NSBezierPath(roundedRect: bottomSwitchRect, xRadius: 48, yRadius: 48).fill()
    cg.saveGState()
    knobShadow.set()
    let bottomKnobRect = NSRect(x: 678, y: 318, width: 76, height: 76)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: bottomKnobRect).fill()
    cg.restoreGState()

    // Inner highlight border on outer squircle
    let innerRim = NSBezierPath(
        roundedRect: squircleRect.insetBy(dx: 2, dy: 2),
        xRadius: cornerRadius - 2,
        yRadius: cornerRadius - 2
    )
    NSColor.white.withAlphaComponent(0.16).setStroke()
    innerRim.lineWidth = 4
    innerRim.stroke()

    cg.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func downscale(_ master: NSBitmapImageRep, to pixelSize: Int) -> Data? {
    if pixelSize == master.pixelsWide {
        return master.representation(using: .png, properties: [:])
    }

    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixelSize, height: pixelSize)

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx

    let masterImage = NSImage(size: NSSize(width: master.pixelsWide, height: master.pixelsHigh))
    masterImage.addRepresentation(master)
    masterImage.draw(
        in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
        from: .zero,
        operation: .copy,
        fraction: 1.0
    )

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let outputDir = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.iconset"
let fm = FileManager.default
try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

let master = renderMasterIcon(size: 1024)
for spec in specs {
    guard let png = downscale(master, to: spec.pixelSize) else {
        fputs("Failed to render \(spec.filename)\n", stderr)
        exit(1)
    }
    let path = (outputDir as NSString).appendingPathComponent(spec.filename)
    try png.write(to: URL(fileURLWithPath: path))
}
print("Generated iconset at \(outputDir)")
