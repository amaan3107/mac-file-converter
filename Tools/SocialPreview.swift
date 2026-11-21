// Draws docs/social-preview.png (1280×640), the image GitHub and LinkedIn show for the repo link.
// Usage: swift Tools/SocialPreview.swift docs/screenshots/main.png docs/social-preview.png
import AppKit

let screenshot = NSImage(contentsOfFile: CommandLine.arguments[1])!
let outURL = URL(fileURLWithPath: CommandLine.arguments[2])
let W = 1280.0, H = 640.0

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W) * 2, pixelsHigh: Int(H) * 2, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Background: the app icon's blue → purple gradient.
NSGradient(colors: [NSColor(red: 0.30, green: 0.36, blue: 0.95, alpha: 1),
                    NSColor(red: 0.55, green: 0.27, blue: 0.88, alpha: 1)])!
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -30)

// App icon badge.
let badge = NSRect(x: 72, y: 430, width: 96, height: 96)
NSColor.white.withAlphaComponent(0.18).setFill()
NSBezierPath(roundedRect: badge, xRadius: 22, yRadius: 22).fill()
let cfg = NSImage.SymbolConfiguration(pointSize: 50, weight: .bold).applying(.init(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    sym.draw(in: NSRect(x: badge.midX - sym.size.width / 2, y: badge.midY - sym.size.height / 2,
                        width: sym.size.width, height: sym.size.height))
}

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, rect: NSRect) {
    let para = NSMutableParagraphStyle(); para.lineSpacing = 6
    NSAttributedString(string: s, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        .paragraphStyle: para,
    ]).draw(with: rect, options: [.usesLineFragmentOrigin])
}
text("Mac File Converter", size: 54, weight: .bold, alpha: 1, rect: NSRect(x: 72, y: 330, width: 560, height: 80))
text("Right-click any file to convert it, shrink it to fit upload limits, or combine into one PDF.",
     size: 26, weight: .medium, alpha: 0.92, rect: NSRect(x: 72, y: 200, width: 520, height: 120))
text("HEIC → JPG  ·  MOV → MP4  ·  Word → PDF  ·  100% local",
     size: 20, weight: .semibold, alpha: 0.8, rect: NSRect(x: 72, y: 110, width: 560, height: 40))

// Screenshot with a soft shadow, bleeding off the right edge.
let shotW = 620.0, shotH = shotW * screenshot.size.height / screenshot.size.width
let shotRect = NSRect(x: 640, y: (H - shotH) / 2 - 10, width: shotW, height: shotH)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 30
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor.white.setFill()
NSBezierPath(roundedRect: shotRect, xRadius: 10, yRadius: 10).fill()
NSGraphicsContext.restoreGraphicsState()
screenshot.draw(in: shotRect)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: outURL)
print("Saved \(outURL.path)")
