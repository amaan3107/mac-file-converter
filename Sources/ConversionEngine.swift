import Foundation
import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// MARK: - File kinds and target formats

enum FileKind: String {
    case image, video, audio, pdf, document, unsupported

    var label: String {
        switch self {
        case .pdf: return "PDF"
        case .unsupported: return "Unsupported"
        default: return rawValue.capitalized
        }
    }
}

enum TargetFormat: String, CaseIterable, Identifiable {
    // Images
    case jpg, png, heic, tiff, gif, bmp, webp
    // Documents
    case pdf, compressedPDF, docx, rtf, txt
    // Video
    case mp4, mov, m4v, animatedGIF
    // Audio
    case mp3, m4a, wav, aac, flac, aiff

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .animatedGIF: return "gif"
        case .compressedPDF: return "pdf"
        default: return rawValue
        }
    }

    var label: String {
        switch self {
        case .animatedGIF: return "GIF (animated)"
        case .compressedPDF: return "PDF (smaller)"
        case .docx: return "Word (DOCX)"
        default: return rawValue.uppercased()
        }
    }

    /// The ImageIO type used when writing this format as a still image.
    var imageUTType: UTType? {
        switch self {
        case .jpg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        case .tiff: return .tiff
        case .gif: return .gif
        case .bmp: return .bmp
        case .webp: return .webP
        default: return nil
        }
    }

    var isLossyImage: Bool { self == .jpg || self == .heic || self == .webp }
}

struct ConversionOptions: Sendable {
    /// Keep the output at or under this many bytes.
    var maxBytes: Int? = nil
    /// Limit the longest side of images and videos to this many pixels.
    var maxDimension: Int? = nil
    /// Remove GPS location from photos and videos.
    var stripLocation: Bool = true
}

enum ConversionError: LocalizedError {
    case message(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        case .cancelled: return "Cancelled"
        }
    }
}

/// Lets the UI stop a running conversion (including a running ffmpeg process).
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.withLock {
            cancelled = true
            if let p = process, p.isRunning { p.terminate() }
        }
    }

    func attach(_ p: Process) {
        lock.withLock {
            process = p
            if cancelled, p.isRunning { p.terminate() }
        }
    }

    func check() throws {
        if isCancelled { throw ConversionError.cancelled }
    }
}

func formatBytes(_ n: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
}

func fileSize(_ url: URL) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
}

struct Formats {
    static let imageWritableTypes: Set<String> = {
        Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
    }()

    static var canWriteWebP: Bool {
        imageWritableTypes.contains(UTType.webP.identifier) || Paths.tool("cwebp") != nil
    }

    static let documentTypes: [UTType] = [
        .rtf, .rtfd, .plainText, .html,
        UTType("org.openxmlformats.wordprocessingml.document"),
        UTType("com.microsoft.word.doc"),
        UTType("org.oasis-open.opendocument.text"),
        UTType("com.apple.webarchive"),
    ].compactMap { $0 }

    static func kind(of url: URL) -> FileKind {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return .unsupported }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if documentTypes.contains(where: { type.conforms(to: $0) }) { return .document }
        return .unsupported
    }

    static func targets(for kind: FileKind, ext: String) -> [TargetFormat] {
        switch kind {
        case .image:
            return [.jpg, .png, .heic, .pdf, .webp, .tiff, .gif, .bmp].filter { fmt in
                if fmt == .webp { return canWriteWebP }
                guard let t = fmt.imageUTType else { return true }
                return imageWritableTypes.contains(t.identifier)
            }
        case .pdf:
            return [.compressedPDF, .jpg, .png, .tiff, .heic]
        case .document:
            return [.pdf, .docx, .rtf, .txt].filter { $0.fileExtension != ext }
        case .video:
            return [.mp4, .mov, .m4v, .animatedGIF, .mp3, .m4a, .wav]
        case .audio:
            return [.mp3, .m4a, .wav, .aac, .flac, .aiff]
        case .unsupported:
            return []
        }
    }

    static func defaultTarget(for url: URL, kind: FileKind) -> TargetFormat? {
        let ext = url.pathExtension.lowercased()
        switch kind {
        case .image: return (ext == "jpg" || ext == "jpeg") ? .png : .jpg
        case .pdf: return .jpg
        case .document: return .pdf
        case .video: return ext == "mp4" ? .mov : .mp4
        case .audio: return ext == "mp3" ? .m4a : .mp3
        case .unsupported: return nil
        }
    }
}

// MARK: - Helpers

enum Paths {
    /// Returns a URL in `folder` named `base.ext` that doesn't collide with an existing file.
    static func uniqueURL(folder: URL, base: String, ext: String) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 1
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    static func tool(_ name: String) -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static func temp(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TheConverter-\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }

    /// Replaces `dest` with `src` (src is moved).
    static func replace(_ dest: URL, with src: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: src, to: dest)
    }
}

// MARK: - Converter

struct Converter {
    /// Converts `input` to `target`. Returns the output file URLs (PDF → images may produce several).
    static func convert(_ input: URL, to target: TargetFormat, kind: FileKind,
                        options: ConversionOptions, token: CancelToken,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        try token.check()
        let folder = input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent
        let out = Paths.uniqueURL(folder: folder, base: base, ext: target.fileExtension)

        do {
            switch kind {
            case .image:
                if target == .pdf {
                    try await makePDF(from: [input], to: out, options: options, token: token)
                } else {
                    try convertImage(input, out, target: target, options: options)
                }
                return [out]
            case .pdf:
                if target == .compressedPDF {
                    try compressPDF(input, to: out, options: options, token: token)
                    return [out]
                }
                return try pdfToImages(input, folder: folder, base: base, target: target, options: options, token: token)
            case .document:
                if target == .pdf {
                    try await makePDF(from: [input], to: out, options: options, token: token)
                } else {
                    try await MainActor.run { try convertDocument(input, out, target: target) }
                }
                return [out]
            case .video, .audio:
                try await runMedia(input, out, target: target, kind: kind, options: options,
                                   token: token, progress: progress)
                return [out]
            case .unsupported:
                throw ConversionError.message("This file type isn't supported.")
            }
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
    }

    // MARK: Images

    /// Loads an image with its rotation applied, optionally scaled so its longest side is at most `maxDimension`.
    static func loadImage(_ url: URL, maxDimension: Int?) throws -> (CGImage, [CFString: Any]) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            throw ConversionError.message("Couldn't read this image.")
        }
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        var longest = max(w, h)
        if longest == 0 { longest = 100_000 }
        if let m = maxDimension { longest = min(longest, m) }

        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longest,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw ConversionError.message("Couldn't read this image.")
        }
        // Rotation is now baked into the pixels.
        props[kCGImagePropertyOrientation] = 1
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        props.removeValue(forKey: kCGImagePropertyPixelWidth)
        props.removeValue(forKey: kCGImagePropertyPixelHeight)
        return (img, props)
    }

    static func convertImage(_ input: URL, _ output: URL, target: TargetFormat, options: ConversionOptions) throws {
        var (img, props) = try loadImage(input, maxDimension: options.maxDimension)
        if options.stripLocation { props.removeValue(forKey: kCGImagePropertyGPSDictionary) }
        if (target == .jpg || target == .bmp), hasAlpha(img) { img = flattenOnWhite(img) ?? img }
        let data = try fitImage(img, props, target: target, maxBytes: options.maxBytes)
        try data.write(to: output)
    }

    /// Encodes the image, lowering quality and then size until it fits `maxBytes`.
    static func fitImage(_ image: CGImage, _ props: [CFString: Any], target: TargetFormat, maxBytes: Int?) throws -> Data {
        let defaultQuality = 0.9
        guard let maxBytes else { return try encode(image, props, target: target, quality: defaultQuality) }

        var img = image
        var smallest = Int.max
        for _ in 0..<12 {
            if target.isLossyImage {
                let full = try encode(img, props, target: target, quality: defaultQuality)
                smallest = min(smallest, full.count)
                if full.count <= maxBytes { return full }
                var lo = 0.4, hi = defaultQuality
                let low = try encode(img, props, target: target, quality: lo)
                smallest = min(smallest, low.count)
                if low.count <= maxBytes {
                    var best = low
                    for _ in 0..<5 {
                        let mid = (lo + hi) / 2
                        let d = try encode(img, props, target: target, quality: mid)
                        if d.count <= maxBytes { best = d; lo = mid } else { hi = mid }
                    }
                    return best
                }
            } else {
                let d = try encode(img, props, target: target, quality: 1)
                smallest = min(smallest, d.count)
                if d.count <= maxBytes { return d }
            }
            guard img.width > 48, img.height > 48, let smaller = scale(img, by: 0.8) else { break }
            img = smaller
        }
        let hint = target.isLossyImage ? "" : " Try JPG instead."
        throw ConversionError.message("Couldn't get it under \(formatBytes(maxBytes)) (smallest was \(formatBytes(smallest))).\(hint)")
    }

    static func encode(_ img: CGImage, _ props: [CFString: Any], target: TargetFormat, quality: Double) throws -> Data {
        if target == .webp, !Formats.imageWritableTypes.contains(UTType.webP.identifier) {
            return try encodeWebPWithCwebp(img, quality: quality)
        }
        guard let type = target.imageUTType else { throw ConversionError.message("Unknown image format.") }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw ConversionError.message("Can't write \(target.label) files on this Mac.")
        }
        var p = props
        p[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(dest, img, p as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.message("Couldn't save the \(target.label) file.") }
        return data as Data
    }

    private static func encodeWebPWithCwebp(_ img: CGImage, quality: Double) throws -> Data {
        guard let cwebp = Paths.tool("cwebp") else { throw ConversionError.message("WEBP needs cwebp: brew install webp") }
        let png = Paths.temp("png"), out = Paths.temp("webp")
        defer { try? FileManager.default.removeItem(at: png); try? FileManager.default.removeItem(at: out) }
        try encode(img, [:], target: .png, quality: 1).write(to: png)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cwebp)
        p.arguments = ["-quiet", "-q", String(Int(quality * 100)), png.path, "-o", out.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ConversionError.message("Couldn't save the WEBP file.") }
        return try Data(contentsOf: out)
    }

    static func hasAlpha(_ img: CGImage) -> Bool {
        switch img.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    private static func rgbSpace(_ img: CGImage) -> CGColorSpace {
        if let cs = img.colorSpace, cs.model == .rgb { return cs }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    static func scale(_ img: CGImage, by factor: Double) -> CGImage? {
        let w = max(1, Int(Double(img.width) * factor)), h = max(1, Int(Double(img.height) * factor))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: rgbSpace(img), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func flattenOnWhite(_ img: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: rgbSpace(img),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(img, in: rect)
        return ctx.makeImage()
    }

    // MARK: PDF building

    /// Builds one PDF from images, PDFs and documents, in order. Used for image → PDF and "Combine into PDF".
    static func makePDF(from inputs: [URL], to output: URL, options: ConversionOptions, token: CancelToken) async throws {
        var temps: [URL] = []
        defer { temps.forEach { try? FileManager.default.removeItem(at: $0) } }

        // Documents are laid out into temporary PDFs first (text layout must run on the main thread).
        var sources: [URL] = []
        for url in inputs {
            if Formats.kind(of: url) == .document {
                let tmp = Paths.temp("pdf")
                temps.append(tmp)
                try await MainActor.run { try documentToPDF(url, tmp) }
                sources.append(tmp)
            } else {
                sources.append(url)
            }
        }

        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(output as CFURL, mediaBox: &box, nil) else {
            throw ConversionError.message("Couldn't create the PDF.")
        }
        var pages = 0
        for url in sources {
            try token.check()
            switch Formats.kind(of: url) {
            case .pdf:
                let doc = try openPDF(url)
                for i in 0..<doc.pageCount {
                    if let page = doc.page(at: i) { drawPDFPage(page, into: ctx); pages += 1 }
                }
            case .image:
                var (img, _) = try loadImage(url, maxDimension: options.maxDimension)
                if hasAlpha(img) { img = flattenOnWhite(img) ?? img }
                let jpeg = try encode(img, [:], target: .jpg, quality: 0.88)
                // Size the page so the longest side is A4 height; the image keeps its full resolution.
                let s = 842.0 / Double(max(img.width, img.height))
                try appendJPEG(jpeg, into: ctx, pageSize: CGSize(width: Double(img.width) * s, height: Double(img.height) * s))
                pages += 1
            default:
                ctx.closePDF()
                throw ConversionError.message("\(url.lastPathComponent) can't be added to a PDF.")
            }
        }
        ctx.closePDF()
        guard pages > 0 else { throw ConversionError.message("Nothing to put in the PDF.") }
        if let max = options.maxBytes { try shrinkPDF(output, maxBytes: max, token: token) }
    }

    static func openPDF(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else {
            throw ConversionError.message("Couldn't open \(url.lastPathComponent).")
        }
        if doc.isLocked, !doc.unlock(withPassword: "") {
            throw ConversionError.message("\(url.lastPathComponent) is password-protected.")
        }
        return doc
    }

    static func pageSize(_ page: PDFPage) -> CGSize {
        let b = page.bounds(for: .cropBox).size
        return page.rotation % 180 == 0 ? b : CGSize(width: b.height, height: b.width)
    }

    /// Draws a PDF page (including filled-in form fields and annotations) as a new page.
    static func drawPDFPage(_ page: PDFPage, into ctx: CGContext) {
        var rect = CGRect(origin: .zero, size: pageSize(page))
        ctx.beginPage(mediaBox: &rect)
        ctx.saveGState()
        page.transform(ctx, for: .cropBox)
        page.draw(with: .cropBox, to: ctx)
        ctx.restoreGState()
        ctx.endPage()
    }

    /// Adds a JPEG as a page. Quartz embeds the JPEG data as-is, so the PDF stays small.
    static func appendJPEG(_ data: Data, into ctx: CGContext, pageSize: CGSize) throws {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ConversionError.message("Couldn't add an image to the PDF.")
        }
        var rect = CGRect(origin: .zero, size: pageSize)
        ctx.beginPage(mediaBox: &rect)
        ctx.draw(img, in: rect)
        ctx.endPage()
    }

    static func renderPage(_ page: PDFPage, scale: CGFloat) -> CGImage? {
        let size = pageSize(page)
        let w = max(1, Int(size.width * scale)), h = max(1, Int(size.height * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.transform(ctx, for: .cropBox)
        page.draw(with: .cropBox, to: ctx)
        return ctx.makeImage()
    }

    /// Re-creates a PDF with every page as a JPEG at the given resolution.
    static func rasterizePDF(_ src: URL, to dst: URL, dpi: CGFloat, quality: Double, token: CancelToken) throws {
        let doc = try openPDF(src)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(dst as CFURL, mediaBox: &box, nil) else { throw ConversionError.message("Couldn't create the PDF.") }
        for i in 0..<doc.pageCount {
            try token.check()
            guard let page = doc.page(at: i), let img = renderPage(page, scale: dpi / 72) else { continue }
            try appendJPEG(try encode(img, [:], target: .jpg, quality: quality), into: ctx, pageSize: pageSize(page))
        }
        ctx.closePDF()
    }

    /// Makes the PDF at `url` fit `maxBytes`: first by compressing its images, then by flattening pages.
    static func shrinkPDF(_ url: URL, maxBytes: Int, token: CancelToken) throws {
        if fileSize(url) <= maxBytes { return }
        let tmp = Paths.temp("pdf")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var smallest = fileSize(url)
        if let doc = PDFDocument(url: url),
           doc.write(to: tmp, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]) {
            smallest = min(smallest, fileSize(tmp))
            if fileSize(tmp) <= maxBytes { try Paths.replace(url, with: tmp); return }
        }
        for (dpi, q) in [(150.0, 0.7), (120, 0.6), (100, 0.5), (80, 0.45), (60, 0.35)] {
            try rasterizePDF(url, to: tmp, dpi: dpi, quality: q, token: token)
            smallest = min(smallest, fileSize(tmp))
            if fileSize(tmp) <= maxBytes { try Paths.replace(url, with: tmp); return }
        }
        throw ConversionError.message("Couldn't get the PDF under \(formatBytes(maxBytes)) (smallest was \(formatBytes(smallest))).")
    }

    static func compressPDF(_ input: URL, to output: URL, options: ConversionOptions, token: CancelToken) throws {
        if let limit = options.maxBytes {
            try FileManager.default.copyItem(at: input, to: output)
            try shrinkPDF(output, maxBytes: limit, token: token)
            return
        }
        let original = fileSize(input)
        let doc = try openPDF(input)
        let optimized = Paths.temp("pdf"), flattened = Paths.temp("pdf")
        defer { [optimized, flattened].forEach { try? FileManager.default.removeItem(at: $0) } }

        var best: URL? = nil
        var bestSize = original
        if doc.write(to: optimized, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]),
           fileSize(optimized) < bestSize {
            best = optimized; bestSize = fileSize(optimized)
        }
        // If compressing images barely helped, try flattening pages at screen quality.
        if Double(bestSize) > Double(original) * 0.8 {
            try rasterizePDF(input, to: flattened, dpi: 150, quality: 0.7, token: token)
            if Double(fileSize(flattened)) < Double(bestSize) * 0.8 { best = flattened; bestSize = fileSize(flattened) }
        }
        guard let best else {
            throw ConversionError.message("This PDF is already about as small as it gets (\(formatBytes(original))).")
        }
        try FileManager.default.moveItem(at: best, to: output)
    }

    static func pdfToImages(_ input: URL, folder: URL, base: String, target: TargetFormat,
                            options: ConversionOptions, token: CancelToken) throws -> [URL] {
        let doc = try openPDF(input)
        guard doc.pageCount > 0 else { throw ConversionError.message("This PDF has no pages.") }
        var outputs: [URL] = []
        do {
            for i in 0..<doc.pageCount {
                try token.check()
                guard let page = doc.page(at: i) else { continue }
                let size = pageSize(page)
                var scale: CGFloat = 200.0 / 72.0 // ~200 DPI
                if let m = options.maxDimension { scale = min(scale, CGFloat(m) / max(size.width, size.height)) }
                guard let img = renderPage(page, scale: scale) else { continue }
                let data = try fitImage(img, [:], target: target, maxBytes: options.maxBytes)
                let name = doc.pageCount == 1 ? base : "\(base) - page \(i + 1)"
                let out = Paths.uniqueURL(folder: folder, base: name, ext: target.fileExtension)
                try data.write(to: out)
                outputs.append(out)
            }
        } catch {
            outputs.forEach { try? FileManager.default.removeItem(at: $0) }
            throw error
        }
        if outputs.isEmpty { throw ConversionError.message("Couldn't render any pages.") }
        return outputs
    }

    // MARK: Documents (Word, RTF, text, HTML)

    @MainActor static func loadDocument(_ url: URL) throws -> NSAttributedString {
        do { return try NSAttributedString(url: url, options: [:], documentAttributes: nil) }
        catch { throw ConversionError.message("Couldn't read this document.") }
    }

    @MainActor static func documentToPDF(_ input: URL, _ output: URL) throws {
        let text = NSMutableAttributedString(attributedString: try loadDocument(input))
        let full = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            if value == nil { text.addAttribute(.foregroundColor, value: NSColor.black, range: range) }
        }

        let info = NSPrintInfo(dictionary: [.jobSavingURL: output])
        info.paperSize = NSSize(width: 612, height: 792)
        info.topMargin = 54; info.bottomMargin = 54; info.leftMargin = 54; info.rightMargin = 54
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        tv.appearance = NSAppearance(named: .aqua)
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.maxSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        tv.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.textStorage?.setAttributedString(text)
        if let lm = tv.layoutManager, let tc = tv.textContainer {
            lm.ensureLayout(for: tc)
            tv.setFrameSize(NSSize(width: width, height: max(lm.usedRect(for: tc).height, 10) + 4))
        }

        let op = NSPrintOperation(view: tv, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run(), FileManager.default.fileExists(atPath: output.path) else {
            throw ConversionError.message("Couldn't create the PDF.")
        }
    }

    @MainActor static func convertDocument(_ input: URL, _ output: URL, target: TargetFormat) throws {
        let text = try loadDocument(input)
        let range = NSRange(location: 0, length: text.length)
        switch target {
        case .txt:
            try text.string.write(to: output, atomically: true, encoding: .utf8)
        case .docx:
            try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
                .write(to: output)
        case .rtf:
            try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                .write(to: output)
        default:
            throw ConversionError.message("Can't convert a document to \(target.label).")
        }
    }

    // MARK: Audio / video via ffmpeg

    /// Scales so the longest side is at most `d` pixels (never upscales; keeps sizes even).
    private static func scaleExpr(_ d: Int) -> String {
        "scale='if(gt(iw,ih),min(\(d),iw),-2)':'if(gt(iw,ih),-2,min(\(d),ih))'"
    }

    private static func videoEncoder(hardware: Bool, kbps: Int?) -> [String] {
        if hardware {
            let rate = kbps.map { ["-b:v", "\($0)k"] } ?? ["-q:v", "65"]
            return ["-c:v", "h264_videotoolbox"] + rate + ["-pix_fmt", "yuv420p"]
        }
        let rate = kbps.map { ["-b:v", "\($0)k", "-maxrate", "\(Int(Double($0) * 1.3))k", "-bufsize", "\($0 * 2)k"] }
            ?? ["-crf", "20"]
        return ["-c:v", "libx264", "-preset", "medium"] + rate + ["-pix_fmt", "yuv420p"]
    }

    private static func audioArgs(_ target: TargetFormat, kbps: Int?) -> [String] {
        switch target {
        case .mp3: return ["-vn", "-c:a", "libmp3lame"] + (kbps.map { ["-b:a", "\($0)k"] } ?? ["-q:a", "2"])
        case .m4a: return ["-vn", "-c:a", "aac", "-b:a", "\(kbps ?? 256)k"]
        case .aac: return ["-vn", "-c:a", "aac", "-b:a", "\(kbps ?? 256)k", "-f", "adts"]
        case .wav: return ["-vn", "-c:a", "pcm_s16le"]
        case .flac: return ["-vn", "-c:a", "flac"]
        case .aiff: return ["-vn", "-c:a", "pcm_s16be"]
        default: return []
        }
    }

    private static func tooBig(_ limit: Int, _ size: Int) -> ConversionError {
        .message("Couldn't get it under \(formatBytes(limit)) (got \(formatBytes(size))). Try a bigger limit or a smaller resize.")
    }

    static func runMedia(_ input: URL, _ output: URL, target: TargetFormat, kind: FileKind,
                         options: ConversionOptions, token: CancelToken,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let ffmpeg = Paths.tool("ffmpeg") else {
            throw ConversionError.message("ffmpeg isn't installed. Run: brew install ffmpeg")
        }
        let duration = probeDuration(input)
        let meta = (kind == .video && options.stripLocation) ? ["-map_metadata", "-1"] : []
        let limit = options.maxBytes

        func run(_ args: [String]) async throws {
            try await ffmpegProcess(ffmpeg, input: input, output: output, args: args + meta,
                                    duration: duration, token: token, progress: progress)
        }
        func needDuration() throws -> Double {
            guard let duration, duration > 0 else { throw ConversionError.message("Couldn't read the length of this file.") }
            return duration
        }

        switch target {
        case .mp4, .mov, .m4v:
            var maxDim = options.maxDimension
            var videoKbps: Int? = nil
            var audioKbps = 192
            if let limit {
                let total = Double(limit) * 8 / (try needDuration()) / 1000 * 0.92
                audioKbps = Int(min(128, max(48, total * 0.12)))
                let v = Int(total) - audioKbps
                guard v >= 120 else {
                    throw ConversionError.message("This video is too long to fit under \(formatBytes(limit)). Try a bigger limit.")
                }
                videoKbps = v
                // Lower bitrates look better at a lower resolution.
                let auto: Int? = v < 700 ? 854 : v < 1800 ? 1280 : v < 5000 ? 1920 : nil
                maxDim = [maxDim, auto].compactMap { $0 }.min()
            }
            let container = target == .mov ? [] : ["-movflags", "+faststart"]
            func args(hardware: Bool, kbps: Int?) -> [String] {
                (maxDim.map { ["-vf", scaleExpr($0)] } ?? []) + videoEncoder(hardware: hardware, kbps: kbps)
                    + ["-c:a", "aac", "-b:a", "\(audioKbps)k"] + container
            }
            do {
                try await run(args(hardware: true, kbps: videoKbps))
            } catch ConversionError.cancelled {
                throw ConversionError.cancelled
            } catch {
                // Hardware encoder failed (unusual input). Retry with the software encoder.
                try await run(args(hardware: false, kbps: videoKbps))
            }
            if let limit, let vk = videoKbps, fileSize(output) > limit {
                let adjusted = max(80, Int(Double(vk) * Double(limit) / Double(fileSize(output)) * 0.9))
                try await run(args(hardware: false, kbps: adjusted))
                if fileSize(output) > limit { throw tooBig(limit, fileSize(output)) }
            }

        case .animatedGIF:
            var ladder: [(fps: Int, width: Int)] = [(12, 720), (10, 540), (8, 420), (6, 320), (5, 240)]
            if let m = options.maxDimension { ladder = ladder.map { ($0.fps, min($0.width, m)) } }
            if limit == nil { ladder = [ladder[0]] }
            for step in ladder {
                try await run(["-vf", "fps=\(step.fps),\(scaleExpr(step.width)):flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4",
                               "-loop", "0", "-an"])
                if limit == nil || fileSize(output) <= limit! { return }
            }
            throw tooBig(limit!, fileSize(output))

        default:
            var kbps: Int? = nil
            if let limit, [.mp3, .m4a, .aac].contains(target) {
                let k = Int(Double(limit) * 8 / (try needDuration()) / 1000 * 0.92)
                guard k >= 32 else {
                    throw ConversionError.message("Too long to fit under \(formatBytes(limit)), even at low quality.")
                }
                if target == .mp3 {
                    // MP3 only allows these bitrates; pick the highest one that fits.
                    kbps = [320, 256, 224, 192, 160, 128, 112, 96, 80, 64, 56, 48, 40, 32].first { $0 <= k } ?? 32
                } else {
                    kbps = min(k, 256)
                }
            }
            try await run(audioArgs(target, kbps: kbps))
            if let limit, fileSize(output) > limit {
                if [.wav, .flac, .aiff].contains(target) {
                    throw ConversionError.message("\(target.label) is uncompressed and can't be shrunk. Pick MP3 or M4A for a smaller file.")
                }
                throw tooBig(limit, fileSize(output))
            }
        }
    }

    private static func probeDuration(_ input: URL) -> Double? {
        guard let ffprobe = Paths.tool("ffprobe") else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffprobe)
        p.arguments = ["-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", input.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Double(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func ffmpegProcess(_ ffmpeg: String, input: URL, output: URL, args: [String],
                                      duration: Double?, token: CancelToken,
                                      progress: @escaping @Sendable (Double) -> Void) async throws {
        try token.check()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-hide_banner", "-nostdin", "-y", "-i", input.path] + args +
                      ["-progress", "pipe:1", "-nostats", output.path]
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        let errBuffer = LockedBuffer()
        errPipe.fileHandleForReading.readabilityHandler = { h in errBuffer.append(h.availableData) }
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            guard let duration, duration > 0 else { return }
            for line in text.split(separator: "\n") where line.hasPrefix("out_time_us=") {
                if let us = Double(line.dropFirst("out_time_us=".count)) {
                    progress(min(1, max(0, us / 1_000_000 / duration)))
                }
            }
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            p.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                if token.isCancelled {
                    cont.resume(throwing: ConversionError.cancelled)
                } else if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let lines = errBuffer.string.split(separator: "\n").suffix(2).joined(separator: " ")
                    cont.resume(throwing: ConversionError.message("ffmpeg failed: \(lines)"))
                }
            }
            do {
                try p.run()
                token.attach(p)
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

final class LockedBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
