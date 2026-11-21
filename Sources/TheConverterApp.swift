import SwiftUI
import AppKit
import UserNotifications

@main
struct TheConverterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { SettingsView() }
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("Open Files…") { appDelegate.openFiles() }
                        .keyboardShortcut("o")
                    Button("Show Converter Window") { appDelegate.showWindow() }
                        .keyboardShortcut("0")
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static weak var shared: AppDelegate?

    private var window: NSWindow?
    private var quickJobs = 0
    /// Set when we were launched for a one-click action, so no window pops up.
    private var suppressAutoWindow = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.servicesProvider = ServiceProvider()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSUpdateDynamicServices()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        FileStore.shared.onIdle = { [weak self] in self?.quitIfIdle() }

        // Files passed on the command line.
        let urls = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }.map { URL(fileURLWithPath: $0) }
        if !urls.isEmpty { openInWindow(urls) }

        // Launched normally (not for a one-click action)? Show the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.quickJobs == 0, !self.suppressAutoWindow, self.window == nil else { return }
            self.showWindow()
        }
    }

    // MARK: Window

    func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "The Converter"
            w.contentViewController = NSHostingController(rootView: ContentView())
            w.setContentSize(NSSize(width: 760, height: 480))
            w.isReleasedWhenClosed = false
            if !w.setFrameUsingName("MainWindow") { w.center() }
            w.setFrameAutosaveName("MainWindow")
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func openInWindow(_ urls: [URL]) {
        FileStore.shared.add(urls)
        showWindow()
    }

    func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { openInWindow(panel.urls) }
    }

    // "Open With › The Converter", dropping on the Dock icon, or `open -a`.
    func application(_ application: NSApplication, open urls: [URL]) {
        openInWindow(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        quickJobs == 0 && !FileStore.shared.isRunning
    }

    private func quitIfIdle() {
        guard quickJobs == 0, !FileStore.shared.isRunning, !(window?.isVisible ?? false) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.quickJobs == 0, !FileStore.shared.isRunning, !(self.window?.isVisible ?? false) else { return }
            NSApp.terminate(nil)
        }
    }

    // MARK: One-click actions (no window)

    func quickConvert(_ urls: [URL], to target: TargetFormat) async {
        suppressAutoWindow = true
        quickJobs += 1
        let store = FileStore.shared
        let opts = ConversionOptions(stripLocation: store.stripLocation)
        var made: [URL] = [], problems: [String] = [], skipped = 0

        for url in urls {
            let kind = Formats.kind(of: url)
            let ext = url.pathExtension.lowercased()
            let alreadyThere = ext == target.fileExtension || (target == .jpg && ext == "jpeg")
            guard Formats.targets(for: kind, ext: ext).contains(target), !alreadyThere else { skipped += 1; continue }
            do {
                made += try await Converter.convert(url, to: target, kind: kind, options: opts,
                                                    token: CancelToken()) { _ in }
                if store.trashOriginals { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            } catch {
                problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        await report(made: made, problems: problems,
                     nothingMessage: skipped > 0 ? "Those files are already \(target.label) or can't become \(target.label)." : nil)
        quickJobs -= 1
        quitIfIdle()
    }

    func quickCombine(_ urls: [URL]) async {
        suppressAutoWindow = true
        quickJobs += 1
        let store = FileStore.shared
        let parts = urls.filter { [.image, .pdf, .document].contains(Formats.kind(of: $0)) }
        if let first = parts.first {
            let out = Paths.uniqueURL(folder: first.deletingLastPathComponent(), base: "Combined", ext: "pdf")
            do {
                try await Converter.makePDF(from: parts, to: out,
                                            options: ConversionOptions(stripLocation: store.stripLocation),
                                            token: CancelToken())
                if store.trashOriginals {
                    parts.forEach { try? FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
                }
                await report(made: [out], problems: [], nothingMessage: nil)
            } catch {
                try? FileManager.default.removeItem(at: out)
                await report(made: [], problems: [error.localizedDescription], nothingMessage: nil)
            }
        } else {
            await report(made: [], problems: [], nothingMessage: "Pick photos, PDFs or documents to combine.")
        }
        quickJobs -= 1
        quitIfIdle()
    }

    private func report(made: [URL], problems: [String], nothingMessage: String?) async {
        if !problems.isEmpty {
            let alert = NSAlert()
            alert.messageText = made.isEmpty ? "Couldn't convert" : "Some files couldn't be converted"
            alert.informativeText = problems.prefix(6).joined(separator: "\n")
            NSApp.activate()
            alert.runModal()
        }
        if !made.isEmpty {
            let title = made.count == 1 ? "Saved \(made[0].lastPathComponent)" : "Converted \(made.count) files"
            let body = FileStore.shared.trashOriginals ? "Originals moved to Trash. Click to show." : "Click to show in Finder."
            await notify(title: title, body: body, reveal: made)
        } else if problems.isEmpty, let nothingMessage {
            await notify(title: "Nothing to convert", body: nothingMessage, reveal: [])
        }
    }

    private func notify(title: String, body: String, reveal: [URL]) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            NSSound(named: "Glass")?.play()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["paths": reveal.map(\.path)]
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // Show banners even while the app is in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // Clicking a notification shows the new files in Finder.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let paths = response.notification.request.content.userInfo["paths"] as? [String] ?? []
        Task { @MainActor in
            self.suppressAutoWindow = true
            let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            self.quitIfIdle()
        }
        completionHandler()
    }
}

/// Backs the Finder right-click items declared under NSServices in Info.plist.
final class ServiceProvider: NSObject {
    private static func urls(_ pboard: NSPasteboard) -> [URL] {
        pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// "Convert with The Converter" — opens the window.
    @objc func convertFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = Self.urls(pboard)
        Task { @MainActor in AppDelegate.shared?.openInWindow(urls) }
    }

    /// "Convert to JPG/PDF/MP4/MP3" — converts right away, no window.
    @objc func quickConvert(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = Self.urls(pboard)
        guard let target = userData.flatMap(TargetFormat.init(rawValue:)) else { return }
        Task { @MainActor in await AppDelegate.shared?.quickConvert(urls, to: target) }
    }

    /// "Combine into PDF" — merges the selected files into one PDF, no window.
    @objc func combineToPDF(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = Self.urls(pboard)
        Task { @MainActor in await AppDelegate.shared?.quickCombine(urls) }
    }
}
