import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var store = FileStore.shared
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            optionsBar
            Divider()
            if store.items.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(store.items) { item in
                        FileRow(item: item, store: store)
                    }
                    .onMove { store.move(from: $0, to: $1) }
                }
                .listStyle(.inset)
            }
            Divider()
            footer
        }
        .frame(minWidth: 700, minHeight: 420)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in store.add([url]) } }
                }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(6)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("The Converter").font(.title2.weight(.semibold))
            Spacer()
            if store.canCombine {
                Button {
                    store.combine()
                } label: {
                    Label("Combine into PDF", systemImage: "doc.on.doc")
                }
                .help("Merge the photos, PDFs and documents into one PDF, in list order. Drag rows to reorder.")
                .disabled(store.isRunning)
            }
            if store.items.count > 1 && !store.allTargets.isEmpty {
                Menu("Convert all to") {
                    ForEach(store.allTargets) { t in
                        Button(t.label) { store.setAll(t) }
                    }
                }
                .fixedSize()
                .disabled(store.isRunning)
            }
            Button("Add Files…") { pickFiles() }
                .disabled(store.isRunning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var optionsBar: some View {
        HStack(spacing: 18) {
            Picker("File size", selection: $store.sizeLimit) {
                ForEach(SizeLimit.allCases) { Text($0.label).tag($0) }
            }
            .fixedSize()
            .help("Shrinks photos, PDFs, videos and audio until they fit, for upload limits.")

            Picker("Resize", selection: $store.resize) {
                ForEach(ResizeOption.allCases) { Text($0.label).tag($0) }
            }
            .fixedSize()
            .help("Limits the longest side of photos and videos.")

            Toggle("Remove location", isOn: $store.stripLocation)
                .toggleStyle(.checkbox)
                .help("Removes GPS location from photos and videos so you don't share where they were taken.")
            Spacer()
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .disabled(store.isRunning)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Drop files here").font(.headline)
            Text("Or right-click files in Finder › Quick Actions › Convert with The Converter.\nOne-click options like Convert to JPG are there too.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle("Move original to Trash after converting", isOn: $store.trashOriginals)
                .toggleStyle(.checkbox)
            Spacer()
            if !store.trashOriginals && store.hasUntrashedConverted && !store.isRunning {
                Button("Move Old Files to Trash") { store.trashAllConvertedOriginals() }
            }
            if !store.items.isEmpty && !store.isRunning {
                Button("Clear") { store.clear() }
            }
            if store.isRunning {
                Button("Cancel") { store.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
            Button {
                store.convertAll()
            } label: {
                if store.isRunning {
                    ProgressView().controlSize(.small).padding(.horizontal, 14)
                } else {
                    Text(store.pendingCount > 1 ? "Convert \(store.pendingCount) Files" : "Convert")
                        .padding(.horizontal, 6)
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(store.isRunning || store.pendingCount == 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { store.add(panel.urls) }
    }
}

struct FileRow: View {
    @ObservedObject var item: FileItem
    let store: FileStore

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.originalTrashed ? (item.outputs.first?.path ?? item.url.path) : item.url.path))
                .resizable()
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(item.originalTrashed && item.outputs.first != item.url, color: .secondary)
                statusLine
            }

            Spacer()

            switch item.status {
            case .ready, .failed:
                if item.targets.isEmpty {
                    Text("Unsupported").foregroundStyle(.secondary)
                } else {
                    Picker("", selection: $item.target) {
                        ForEach(item.targets) { t in
                            Text(t.label).tag(Optional(t))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .disabled(store.isRunning)
                }
                Button {
                    store.remove(item)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(store.isRunning)
            case .converting(let p):
                if let p {
                    ProgressView(value: p).frame(width: 150)
                } else {
                    ProgressView().controlSize(.small)
                }
            case .done, .combined:
                if !item.originalTrashed {
                    Button("Move Original to Trash") { store.trashOriginal(item) }
                        .controlSize(.small)
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(item.outputs)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch item.status {
        case .ready:
            Text(item.kind == .unsupported ? "Can't convert this file type" : "\(item.kind.label) · \(formatBytes(item.originalSize))")
                .font(.caption).foregroundStyle(.secondary)
        case .converting(let p):
            Text(p.map { "Converting… \(Int($0 * 100))%" } ?? "Converting…")
                .font(.caption).foregroundStyle(.secondary)
        case .done(let urls):
            let total = urls.reduce(0) { $0 + fileSize($1) }
            let names = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
            Label("Saved \(names) (\(formatBytes(total)))" + (item.originalTrashed ? " · original moved to Trash" : ""),
                  systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .combined(let url):
            Label("Added to \(url.lastPathComponent) (\(formatBytes(fileSize(url))))" + (item.originalTrashed ? " · original moved to Trash" : ""),
                  systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store = FileStore.shared

    var body: some View {
        Form {
            Toggle("Move original to Trash after converting", isOn: $store.trashOriginals)
            Toggle("Remove location from photos and videos", isOn: $store.stripLocation)
            Text("These also apply to the one-click right-click actions (Convert to JPG, etc.).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 420)
    }
}
