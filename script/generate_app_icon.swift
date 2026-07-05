import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Resources/OpenFinder.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

struct RGBA {
    let r: CGFloat
    let g: CGFloat
    let b: CGFloat
    let a: CGFloat

    var color: NSColor { NSColor(calibratedRed: r, green: g, blue: b, alpha: a) }
}

func scaled(_ value: CGFloat, _ size: CGFloat) -> CGFloat {
    value * size / 1024.0
}

func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ size: CGFloat) -> NSRect {
    NSRect(x: scaled(x, size), y: scaled(y, size), width: scaled(width, size), height: scaled(height, size))
}

func rounded(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, radius: CGFloat, size: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect(x, y, width, height, size), xRadius: scaled(radius, size), yRadius: scaled(radius, size))
}

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSGraphicsContext.current?.imageInterpolation = .high
    NSGraphicsContext.current?.shouldAntialias = true

    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    canvas.fill()

    let background = rounded(58, 58, 908, 908, radius: 210, size: size)
    NSGradient(colors: [
        RGBA(r: 0.05, g: 0.24, b: 0.78, a: 1).color,
        RGBA(r: 0.02, g: 0.55, b: 0.94, a: 1).color,
        RGBA(r: 0.08, g: 0.86, b: 0.72, a: 1).color
    ])?.draw(in: background, angle: 45)

    RGBA(r: 1, g: 1, b: 1, a: 0.24).color.setStroke()
    background.lineWidth = scaled(18, size)
    background.stroke()

    NSShadow().apply { shadow in
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowOffset = NSSize(width: 0, height: -scaled(26, size))
        shadow.shadowBlurRadius = scaled(42, size)
    }

    let folderBack = rounded(156, 340, 712, 390, radius: 82, size: size)
    RGBA(r: 0.78, g: 0.93, b: 1.0, a: 0.94).color.setFill()
    folderBack.fill()

    let tab = rounded(184, 490, 286, 154, radius: 48, size: size)
    RGBA(r: 0.92, g: 0.98, b: 1.0, a: 0.98).color.setFill()
    tab.fill()

    let folderFront = rounded(126, 266, 772, 424, radius: 96, size: size)
    NSGradient(colors: [
        RGBA(r: 1.0, g: 1.0, b: 1.0, a: 0.98).color,
        RGBA(r: 0.74, g: 0.94, b: 1.0, a: 0.96).color
    ])?.draw(in: folderFront, angle: -90)

    NSColor.black.withAlphaComponent(0.10).setStroke()
    folderFront.lineWidth = scaled(10, size)
    folderFront.stroke()

    NSGraphicsContext.saveGraphicsState()
    folderFront.addClip()

    let leftPane = rounded(214, 344, 250, 258, radius: 46, size: size)
    RGBA(r: 0.02, g: 0.47, b: 0.95, a: 1).color.setFill()
    leftPane.fill()

    let rightPane = rounded(528, 344, 282, 258, radius: 46, size: size)
    RGBA(r: 0.08, g: 0.82, b: 0.72, a: 1).color.setFill()
    rightPane.fill()

    RGBA(r: 1, g: 1, b: 1, a: 0.45).color.setFill()
    NSBezierPath(roundedRect: rect(258, 528, 144, 30, size), xRadius: scaled(15, size), yRadius: scaled(15, size)).fill()
    NSBezierPath(roundedRect: rect(258, 472, 156, 30, size), xRadius: scaled(15, size), yRadius: scaled(15, size)).fill()
    NSBezierPath(roundedRect: rect(258, 416, 120, 30, size), xRadius: scaled(15, size), yRadius: scaled(15, size)).fill()

    RGBA(r: 1, g: 1, b: 1, a: 0.58).color.setFill()
    NSBezierPath(roundedRect: rect(572, 528, 164, 30, size), xRadius: scaled(15, size), yRadius: scaled(15, size)).fill()
    NSBezierPath(roundedRect: rect(572, 472, 118, 30, size), xRadius: scaled(15, size), yRadius: scaled(15, size)).fill()
    NSBezierPath(roundedRect: rect(572, 416, 156, 30, size), xRadius: scaled(15, size), yRadius: scaled(15, size)).fill()

    RGBA(r: 0.04, g: 0.18, b: 0.46, a: 0.18).color.setFill()
    NSBezierPath(roundedRect: rect(494, 334, 32, 280, size), xRadius: scaled(16, size), yRadius: scaled(16, size)).fill()

    NSGraphicsContext.restoreGraphicsState()

    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: scaled(410, size), y: scaled(220, size)))
    arrow.line(to: NSPoint(x: scaled(668, size), y: scaled(220, size)))
    arrow.line(to: NSPoint(x: scaled(668, size), y: scaled(160, size)))
    arrow.line(to: NSPoint(x: scaled(812, size), y: scaled(286, size)))
    arrow.line(to: NSPoint(x: scaled(668, size), y: scaled(412, size)))
    arrow.line(to: NSPoint(x: scaled(668, size), y: scaled(352, size)))
    arrow.line(to: NSPoint(x: scaled(410, size), y: scaled(352, size)))
    arrow.close()

    RGBA(r: 1, g: 1, b: 1, a: 0.98).color.setFill()
    arrow.fill()
    RGBA(r: 0.02, g: 0.28, b: 0.70, a: 0.24).color.setStroke()
    arrow.lineJoinStyle = .round
    arrow.lineWidth = scaled(9, size)
    arrow.stroke()

    return image
}

extension NSShadow {
    func apply(_ configure: (NSShadow) -> Void) {
        configure(self)
        set()
    }
}

func writePNG(size: Int, name: String) throws {
    let image = drawIcon(size: CGFloat(size))
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "OpenFinderIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not render \(name)"])
    }
    try png.write(to: iconset.appendingPathComponent(name), options: .atomic)
}

let outputs: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

for (size, name) in outputs {
    try writePNG(size: size, name: name)
}

let icns = root.appendingPathComponent("Resources/OpenFinder.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    throw NSError(domain: "OpenFinderIcon", code: Int(iconutil.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
}

if ProcessInfo.processInfo.environment["KEEP_ICONSET"] != "1" {
    try? FileManager.default.removeItem(at: iconset)
}
