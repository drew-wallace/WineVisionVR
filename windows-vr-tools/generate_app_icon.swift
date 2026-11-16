#!/usr/bin/env swift
// Regenerate the WineVision icon with: swift windows-vr-tools/generate_app_icon.swift
// All artwork is drawn here; no external fonts, images, or packages are required.
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("visionos-windows-vr/Resources/Assets.xcassets")
let stack = assets.appendingPathComponent("AppIcon.solidimagestack")
let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 255) / 255,
        CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, alpha])!
}

func gradient(_ colors: [CGColor], _ stops: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: stops)!
}

func render(_ draw: (CGContext) -> Void) -> CGImage {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: 1, y: -1)
    draw(context)
    return context.makeImage()!
}

func save(_ image: CGImage, _ url: URL, opaque: Bool = false) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let bitmap = NSBitmapImageRep(cgImage: image)
    // The background must have no alpha channel, including fully opaque alpha.
    if opaque {
        let rgb = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rgb)
        bitmap.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        try rgb.representation(using: .png, properties: [:])!.write(to: url)
    } else {
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}

func json(_ object: [String: Any], at directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try (data + Data([10])).write(to: directory.appendingPathComponent("Contents.json"))
}

func stroke(_ context: CGContext, _ path: CGPath, _ tint: CGColor, _ width: CGFloat) {
    context.addPath(path)
    context.setStrokeColor(tint)
    context.setLineWidth(width)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()
}

func lens(_ offset: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 238 + offset, y: 410))
    p.addCurve(to: CGPoint(x: 463 + offset, y: 410), control1: CGPoint(x: 285 + offset, y: 392), control2: CGPoint(x: 417 + offset, y: 392))
    p.addCurve(to: CGPoint(x: 449 + offset, y: 596), control1: CGPoint(x: 484 + offset, y: 438), control2: CGPoint(x: 476 + offset, y: 555))
    p.addCurve(to: CGPoint(x: 259 + offset, y: 596), control1: CGPoint(x: 419 + offset, y: 631), control2: CGPoint(x: 289 + offset, y: 631))
    p.addCurve(to: CGPoint(x: 238 + offset, y: 410), control1: CGPoint(x: 230 + offset, y: 560), control2: CGPoint(x: 217 + offset, y: 441))
    p.closeSubpath()
    return p
}

let background = render { c in
    c.drawLinearGradient(gradient([color(0x472238), color(0x241729), color(0x13121F)], [0, 0.55, 1]),
        start: CGPoint(x: 220, y: 0), end: CGPoint(x: 820, y: 1024), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.drawRadialGradient(gradient([color(0xB65A73, 0.24), color(0xB65A73, 0)]),
        startCenter: CGPoint(x: 500, y: 405), startRadius: 0,
        endCenter: CGPoint(x: 500, y: 405), endRadius: 530, options: [])
}

// Keep wine and frames on the same depth plane so parallax never separates them.
let glasses = render { c in
    let bridge = CGMutablePath()
    bridge.move(to: CGPoint(x: 477, y: 451))
    bridge.addCurve(to: CGPoint(x: 547, y: 451), control1: CGPoint(x: 493, y: 430), control2: CGPoint(x: 531, y: 430))
    let temples = CGMutablePath()
    temples.move(to: CGPoint(x: 233, y: 431))
    temples.addLine(to: CGPoint(x: 197, y: 390))
    temples.move(to: CGPoint(x: 791, y: 431))
    temples.addLine(to: CGPoint(x: 827, y: 390))
    stroke(c, temples, color(0xBEA5A6), 23)
    stroke(c, bridge, color(0xF5DFD1), 25)

    for offset: CGFloat in [0, 322] {
        let shape = lens(offset)
        c.saveGState()
        c.addPath(shape)
        c.clip()
        c.drawLinearGradient(gradient([color(0xC6A6B4, 0.24), color(0x956582, 0.12)]),
            start: CGPoint(x: 0, y: 398), end: CGPoint(x: 0, y: 620), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

        let wine = CGMutablePath()
        wine.move(to: CGPoint(x: 210 + offset, y: 516))
        wine.addCurve(to: CGPoint(x: 490 + offset, y: 516),
            control1: CGPoint(x: 310 + offset, y: 495), control2: CGPoint(x: 380 + offset, y: 543))
        wine.addLine(to: CGPoint(x: 490 + offset, y: 650))
        wine.addLine(to: CGPoint(x: 210 + offset, y: 650))
        wine.closeSubpath()
        c.saveGState()
        c.addPath(wine)
        c.clip()
        c.drawLinearGradient(gradient([color(0xEC516C), color(0xB91F4D), color(0x690F35)], [0, 0.45, 1]),
            start: CGPoint(x: 270 + offset, y: 505), end: CGPoint(x: 435 + offset, y: 637),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        c.restoreGState()

        let surface = CGMutablePath()
        surface.move(to: CGPoint(x: 210 + offset, y: 516))
        surface.addCurve(to: CGPoint(x: 490 + offset, y: 516),
            control1: CGPoint(x: 310 + offset, y: 495), control2: CGPoint(x: 380 + offset, y: 543))
        stroke(c, surface, color(0xFF9AA9, 0.8), 5)

        let reflection = CGMutablePath()
        reflection.move(to: CGPoint(x: 264 + offset, y: 473))
        reflection.addCurve(to: CGPoint(x: 275 + offset, y: 442),
            control1: CGPoint(x: 260 + offset, y: 452), control2: CGPoint(x: 262 + offset, y: 444))
        stroke(c, reflection, color(0xFFF4E8, 0.65), 12)
        c.restoreGState()

        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: 8), blur: 18, color: color(0x08040F, 0.6))
        stroke(c, shape, color(0xC3A9A8), 29)
        c.restoreGState()
        c.saveGState()
        c.addPath(shape.copy(strokingWithWidth: 23, lineCap: .round, lineJoin: .round, miterLimit: 10))
        c.clip()
        c.drawLinearGradient(gradient([color(0xFFF3DF), color(0xE4C6BE), color(0xC4A6AD)], [0, 0.55, 1]),
            start: CGPoint(x: 0, y: 390), end: CGPoint(x: 0, y: 630), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        c.restoreGState()
    }
}

let info: [String: Any] = ["author": "xcode", "version": 1]
try json(["info": info], at: assets)
try json(["info": info, "layers": [["filename": "Front.solidimagestacklayer"],
    ["filename": "Back.solidimagestacklayer"]]], at: stack)
for (name, image) in [("Back", background), ("Front", glasses)] {
    let layer = stack.appendingPathComponent("\(name).solidimagestacklayer")
    let content = layer.appendingPathComponent("Content.imageset")
    try json(["info": info], at: layer)
    try json(["info": info, "images": [["filename": "\(name).png", "idiom": "vision", "scale": "2x"]]], at: content)
    try save(image, content.appendingPathComponent("\(name).png"), opaque: name == "Back")
}

let preview = render { c in
    c.addEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
    c.clip()
    // CGImages are drawn upright after undoing the drawing coordinate transform.
    c.translateBy(x: 0, y: CGFloat(size))
    c.scaleBy(x: 1, y: -1)
    c.draw(background, in: CGRect(x: 0, y: 0, width: size, height: size))
    c.draw(glasses, in: CGRect(x: 0, y: 0, width: size, height: size))
}
try save(preview, root.appendingPathComponent("docs/images/winevision-icon.png"))
print("Generated layered AppIcon and docs/images/winevision-icon.png")
