import Foundation
import AppKit

enum ItemStatus: Equatable {
    case ready
    case converting(Double?)
    case done([URL])
    case combined(URL)
    case failed(String)
}

enum SizeLimit: Int, CaseIterable, Identifiable {
    case off = 0
    case kb200 = 200_000, kb500 = 500_000
    case mb1 = 1_000_000, mb2 = 2_000_000, mb5 = 5_000_000, mb10 = 10_000_000, mb25 = 25_000_000

    var id: Int { rawValue }
    var bytes: Int? { self == .off ? nil : rawValue }
    var label: String {
        switch self {
        case .off: return "Any size"
        default: return rawValue >= 1_000_000 ? "Under \(rawValue / 1_000_000) MB" : "Under \(rawValue / 1000) KB"
        }
    }
}

enum ResizeOption: Int, CaseIterable, Identifiable {
    case original = 0, px3840 = 3840, px2560 = 2560, px1920 = 1920, px1280 = 1280, px1024 = 1024, px800 = 800

    var id: Int { rawValue }
    var label: String { self == .original ? "Original size" : "Max \(rawValue) px" }
}

@MainActor
final class FileItem: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    let kind: FileKind
    let targets: [TargetFormat]
    let originalSize: Int
    @Published var target: TargetFormat?
    @Published var status: ItemStatus = .ready
    @Published var originalTrashed = false

    init(url: URL) {
        self.url = url
        self.kind = Formats.kind(of: url)
        self.targets = Formats.targets(for: kind, ext: url.pathExtension.lowercased())
        self.target = Formats.defaultTarget(for: url, kind: kind)
        self.originalSize = fileSize(url)
    }

    var outputs: [URL] {
        switch status {
        case .done(let urls): return urls
        case .combined(let url): return [url]
        default: return []
        }
    }

    var isDone: Bool { !outputs.isEmpty }
    var isConverting: Bool { if case .converting = status { return true }; return false }
}

@MainActor
final class FileStore: ObservableObject {
    static let shared = FileStore()

    @Published var items: [FileItem] = []
    @Published var isRunning = false
    @Published var sizeLimit: SizeLimit = .off
    @Published var resize: ResizeOption = .original
    @Published var trashOriginals: Bool {
        didSet { UserDefaults.standard.set(trashOriginals, forKey: "trashOriginals") }
    }
    @Published var stripLocation: Bool {
        didSet { UserDefaults.standard.set(stripLocation, forKey: "stripLocation") }
    }

    /// Called when a batch finishes, so the app can quit if its window is closed.
    var onIdle: (() -> Void)?
    private var token: CancelToken?

    private init() {
        let d = UserDefaults.standard
        trashOriginals = d.object(forKey: "trashOriginals") as? Bool ?? true
        stripLocation = d.object(forKey: "stripLocation") as? Bool ?? true
    }

    var options: ConversionOptions {
        ConversionOptions(maxBytes: sizeLimit.bytes,
                          maxDimension: resize == .original ? nil : resize.rawValue,
                          stripLocation: stripLocation)
    }

    func add(_ urls: [URL]) {
        // If everything in the list is finished, start fresh for the new batch.
        if !isRunning, !items.isEmpty, items.allSatisfy({ $0.isDone || $0.kind == .unsupported }) {
            items.removeAll()
        }
        let existing = Set(items.map { $0.url.standardizedFileURL })
        for url in urls where !existing.contains(url.standardizedFileURL) {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            items.append(FileItem(url: url))
        }
    }

    func remove(_ item: FileItem) { items.removeAll { $0.id == item.id } }
    func clear() { items.removeAll() }
    func move(from: IndexSet, to: Int) { items.move(fromOffsets: from, toOffset: to) }

    /// All formats offered by at least one file in the list, for the "Convert all to" menu.
    var allTargets: [TargetFormat] {
        let set = Set(items.flatMap { $0.targets })
        return TargetFormat.allCases.filter { set.contains($0) }
    }

    func setAll(_ target: TargetFormat) {
        for item in items where item.targets.contains(target) && !item.isDone {
            item.target = target
        }
    }

    var pendingCount: Int {
        items.filter { !$0.isDone && !$0.isConverting && $0.target != nil }.count
    }

    // MARK: Converting

    func convertAll() {
        guard !isRunning else { return }
        isRunning = true
        let token = CancelToken()
        self.token = token
        let opts = options
        let queue = items.filter { !$0.isDone && $0.target != nil }
        Task {
            for item in queue {
                if token.isCancelled { break }
                await convert(item, options: opts, token: token)
            }
            finish()
        }
    }

    private func convert(_ item: FileItem, options: ConversionOptions, token: CancelToken) async {
        guard let target = item.target else { return }
        item.status = .converting(nil)
        do {
            let outputs = try await Converter.convert(item.url, to: target, kind: item.kind,
                                                      options: options, token: token) { p in
                Task { @MainActor in
                    if item.isConverting { item.status = .converting(p) }
                }
            }
            item.status = .done(outputs)
            if trashOriginals { trashOriginal(item) }
        } catch ConversionError.cancelled {
            item.status = .ready
        } catch {
            item.status = .failed(error.localizedDescription)
        }
    }

    func cancel() { token?.cancel() }

    private func finish() {
        isRunning = false
        token = nil
        onIdle?()
    }

    // MARK: Combine into one PDF

    var combinable: [FileItem] {
        items.filter { [.image, .pdf, .document].contains($0.kind) && !$0.isDone }
    }

    var canCombine: Bool { combinable.count >= 2 }

    func combine() {
        let parts = combinable
        guard parts.count >= 2, !isRunning else { return }
        isRunning = true
        let token = CancelToken()
        self.token = token
        let opts = options
        parts.forEach { $0.status = .converting(nil) }

        let folder = parts[0].url.deletingLastPathComponent()
        let out = Paths.uniqueURL(folder: folder, base: "Combined", ext: "pdf")
        Task {
            do {
                try await Converter.makePDF(from: parts.map(\.url), to: out, options: opts, token: token)
                for p in parts {
                    p.status = .combined(out)
                    if trashOriginals { trashOriginal(p) }
                }
            } catch {
                try? FileManager.default.removeItem(at: out)
                let cancelled = (error as? ConversionError).map { if case .cancelled = $0 { return true }; return false } ?? false
                for p in parts { p.status = cancelled ? .ready : .failed(error.localizedDescription) }
            }
            finish()
        }
    }

    // MARK: Trash

    func trashOriginal(_ item: FileItem) {
        guard !item.originalTrashed else { return }
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            item.originalTrashed = true
        } catch {
            item.status = .failed("Converted, but couldn't move the original to Trash: \(error.localizedDescription)")
            return
        }
        // e.g. shrinking photo.jpg made "photo (1).jpg"; now that the original is gone, take its name.
        if case .done(let outs) = item.status, outs.count == 1 {
            let out = outs[0]
            if out.pathExtension.lowercased() == item.url.pathExtension.lowercased(),
               !FileManager.default.fileExists(atPath: item.url.path),
               (try? FileManager.default.moveItem(at: out, to: item.url)) != nil {
                item.status = .done([item.url])
            }
        }
    }

    func trashAllConvertedOriginals() {
        for item in items where item.isDone && !item.originalTrashed {
            trashOriginal(item)
        }
    }

    var hasUntrashedConverted: Bool {
        items.contains { $0.isDone && !$0.originalTrashed }
    }
}
