// Renders the app's window with example files into PNGs for the README.
// Run via Tools/make_screenshots.sh — no screen recording permission needed.
import AppKit
import SwiftUI

@main
enum Screenshots {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()

        let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
        let demoDir = URL(fileURLWithPath: CommandLine.arguments[2])
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: demoDir, withIntermediateDirectories: true)

        // Placeholder files so names, icons and sizes look real (sparse, so they take no disk space).
        func demo(_ name: String, _ bytes: Int) -> URL {
            let url = demoDir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            if let h = try? FileHandle(forWritingTo: url) { try? h.truncate(atOffset: UInt64(bytes)); try? h.close() }
            return url
        }
        let heic = demo("IMG_4021.HEIC", 4_120_000)
        let jpg = demo("IMG_4021.jpg", 1_870_000)
        let mov = demo("Beach trip.MOV", 182_400_000)
        let pdf = demo("Lease agreement.pdf", 12_800_000)
        let m4a = demo("Voice memo.m4a", 6_200_000)
        let docx = demo("Resume.docx", 48_000)

        let store = FileStore.shared
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 760, height: 470),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "The Converter"
        window.contentViewController = NSHostingController(rootView: ContentView())
        window.setContentSize(NSSize(width: 760, height: 470))
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()

        func shot(_ file: String, dark: Bool, setup: () -> Void) {
            setup()
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
            guard let frameView = window.contentView?.superview else { return }
            let bounds = frameView.bounds
            guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            frameView.cacheDisplay(in: bounds, to: rep)

            // Round the corners like a real macOS window.
            let img = NSImage(size: bounds.size)
            img.addRepresentation(rep)
            let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            out.size = bounds.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
            NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).addClip()
            img.draw(in: bounds)
            NSGraphicsContext.restoreGraphicsState()
            try? out.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent(file))
            print("Saved \(file)")
        }

        // 1. Ready to convert, with one file already done and a 2 MB upload limit.
        shot("main.png", dark: false) {
            store.clear()
            store.add([heic, mov, pdf, m4a, docx])
            store.sizeLimit = .mb2
            store.items[0].status = .done([jpg])
            store.items[0].originalTrashed = true
            store.items[2].target = .compressedPDF
        }

        // 2. Mid-conversion in dark mode.
        shot("converting-dark.png", dark: true) {
            store.clear()
            store.add([mov, pdf, docx])
            store.sizeLimit = .mb25
            store.isRunning = true
            store.items[0].status = .converting(0.62)
            store.items[2].target = .pdf
        }

        // 3. Empty window.
        shot("empty.png", dark: false) {
            store.isRunning = false
            store.clear()
            store.sizeLimit = .off
        }
    }
}
