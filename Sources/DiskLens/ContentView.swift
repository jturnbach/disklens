import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var root: FileNode?
    @Published var zoomRoot: FileNode?
    @Published var selectedNodes: [FileNode] = []
    @Published var isScanning = false
    @Published var progressFiles = 0
    @Published var progressBytes: Int64 = 0
    @Published var progressPath: String = ""
    @Published var statusText: String = "Ready. Choose a folder to scan."
    @Published var legend: [(FileCategory, Int64)] = []
    @Published var showPreview: Bool = false
    @Published var showWelcome: Bool = true

    // Set when the scan root happens to be the mount point of a volume. Used
    // by the side pane to draw a "free space" tail on the stacked bar so the
    // bar can represent total volume capacity, not just what we scanned.
    @Published var volumeName: String? = nil
    @Published var volumeFreeBytes: Int64 = 0
    @Published var volumeTotalBytes: Int64 = 0
    @Published var scanRootIsVolume: Bool = false

    // ----- AI assistant state -----
    @Published var aiProvider: AIProvider? = nil
    @Published var aiModel: String = ""
    @Published var aiMessages: [ChatMessage] = []
    @Published var aiSending: Bool = false
    @Published var showAIChat: Bool = false
    @Published var showAISetup: Bool = false

    var aiClient: AIClient? {
        guard let provider = aiProvider,
              let key = Keychain.load(account: provider.keychainAccount),
              !key.isEmpty else { return nil }
        return AIClient(provider: provider,
                        apiKey: key,
                        model: aiModel.isEmpty ? provider.defaultModel : aiModel)
    }

    var aiConnected: Bool { aiClient != nil }

    // Persists which provider the user picked (the actual key lives in the
    // Keychain — we only store the provider id and model in defaults).
    private let activeProviderKey = "DiskLens.activeAIProvider"
    private let activeModelKey    = "DiskLens.activeAIModel"

    func loadAISettings() {
        if let raw = UserDefaults.standard.string(forKey: activeProviderKey),
           let provider = AIProvider(rawValue: raw),
           Keychain.load(account: provider.keychainAccount) != nil {
            aiProvider = provider
            aiModel = UserDefaults.standard.string(forKey: activeModelKey)
                ?? provider.defaultModel
        }
    }

    func setAIProvider(_ provider: AIProvider, apiKey: String, model: String) throws {
        try Keychain.save(account: provider.keychainAccount, value: apiKey)
        aiProvider = provider
        aiModel = model
        UserDefaults.standard.set(provider.rawValue, forKey: activeProviderKey)
        UserDefaults.standard.set(model, forKey: activeModelKey)
        aiMessages = []
    }

    func disconnectAI() {
        if let p = aiProvider {
            Keychain.delete(account: p.keychainAccount)
        }
        aiProvider = nil
        aiModel = ""
        aiMessages = []
        UserDefaults.standard.removeObject(forKey: activeProviderKey)
        UserDefaults.standard.removeObject(forKey: activeModelKey)
    }

    func sendAIMessage(_ text: String) {
        guard let client = aiClient else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        aiMessages.append(ChatMessage(role: .user, content: trimmed))
        aiSending = true

        let system = ScanContext.systemPrompt(for: self)
        let history = aiMessages
        Task { @MainActor in
            do {
                let reply = try await client.send(system: system, history: history)
                aiMessages.append(ChatMessage(role: .assistant, content: reply))
            } catch {
                aiMessages.append(ChatMessage(
                    role: .assistant,
                    content: "Error: \(error.localizedDescription)",
                    isError: true))
            }
            aiSending = false
        }
    }

    func clearAIChat() { aiMessages = [] }

    // The most recently focused node — used for single-target operations like
    // zoom, preview, status bar. Multi-target operations use selectedNodes.
    var primarySelected: FileNode? { selectedNodes.last }
    var hasSelection: Bool { !selectedNodes.isEmpty }
    var selectionTotalSize: Int64 {
        canonicalSelection().reduce(0) { $0 + $1.totalSize }
    }

    // De-duplicates a multi-selection so an ancestor and its descendant
    // aren't both treated as roots — important for trash, where removing a
    // parent already removes its children.
    func canonicalSelection() -> [FileNode] {
        let ids = Set(selectedNodes.map { ObjectIdentifier($0) })
        return selectedNodes.filter { node in
            var p = node.parent
            while let cur = p {
                if ids.contains(ObjectIdentifier(cur)) { return false }
                p = cur.parent
            }
            return true
        }
    }

    // Bumped any time the file tree mutates so observers (outline, treemap)
    // know to invalidate cached state. Reference equality alone is unreliable
    // because we mutate nodes in place during trash.
    @Published var mutationToken: Int = 0

    private let scanner = Scanner()

    func chooseAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to analyze"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let url = panel.url {
            startScan(url: url)
        }
    }

    func startScan(url: URL) {
        showWelcome = false
        isScanning = true
        root = nil
        zoomRoot = nil
        selectedNodes = []
        legend = []
        progressFiles = 0
        progressBytes = 0
        statusText = "Scanning \(url.path)…"
        scanner.scan(root: url, progress: { [weak self] p in
            guard let self else { return }
            self.progressFiles = p.filesScanned
            self.progressBytes = p.bytesScanned
            self.progressPath = p.currentPath
        }, completion: { [weak self] node in
            guard let self else { return }
            self.isScanning = false
            self.root = node
            self.zoomRoot = node
            self.selectedNodes = node.map { [$0] } ?? []
            self.mutationToken += 1
            if let node = node {
                self.statusText = "\(node.fileCount.formatted()) files · \(node.dirCount.formatted()) folders · \(ByteFormatter.string(node.totalSize)) — \(node.url.path)"
                self.legend = self.computeLegend(root: node)
                self.captureVolumeInfo(scanRoot: node.url)
            } else {
                self.statusText = "Scan cancelled."
            }
        })
    }

    func cancelScan() {
        scanner.cancel()
    }

    func zoomIn(_ node: FileNode) {
        if node.isDirectory {
            zoomRoot = node
            selectedNodes = [node]
        }
    }

    func zoomOut() {
        if let cur = zoomRoot, let parent = cur.parent {
            zoomRoot = parent
            selectedNodes = [parent]
        } else {
            zoomRoot = root
        }
    }

    func resetZoom() {
        zoomRoot = root
    }

    func moveSelectionToTrash() {
        let nodes = canonicalSelection().filter { $0 !== root }
        guard !nodes.isEmpty else { NSSound.beep(); return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.addButton(withTitle: nodes.count == 1
                        ? "Move to Trash"
                        : "Move \(nodes.count) Items to Trash")
        alert.addButton(withTitle: "Cancel")
        if nodes.count == 1, let n = nodes.first {
            alert.messageText = "Move to Trash?"
            alert.informativeText = "“\(n.name)” (\(ByteFormatter.string(n.totalSize))) will be moved to the Trash."
        } else {
            let total = nodes.reduce(0) { $0 + $1.totalSize }
            alert.messageText = "Move \(nodes.count) items to Trash?"
            alert.informativeText = "\(ByteFormatter.string(total)) total. This cannot be undone from within DiskLens."
        }
        if alert.runModal() != .alertFirstButtonReturn { return }

        var failures: [(FileNode, Error)] = []
        // Sort by descending depth so we trash leaves before their parents,
        // avoiding "file already gone" errors when both are selected.
        let ordered = nodes.sorted { depth($0) > depth($1) }
        for n in ordered {
            do {
                var trashed: NSURL? = nil
                try FileManager.default.trashItem(at: n.url, resultingItemURL: &trashed)
                removeNodeFromTree(n)
            } catch {
                failures.append((n, error))
            }
        }
        if !failures.isEmpty {
            let e = NSAlert()
            e.messageText = "Could not move \(failures.count) item\(failures.count == 1 ? "" : "s") to Trash"
            e.informativeText = failures.prefix(5)
                .map { "• \($0.0.name): \($0.1.localizedDescription)" }
                .joined(separator: "\n")
            e.alertStyle = .critical
            e.addButton(withTitle: "OK")
            e.runModal()
        }
    }

    private func depth(_ n: FileNode) -> Int {
        var d = 0
        var p = n.parent
        while let cur = p { d += 1; p = cur.parent }
        return d
    }

    func revealSelectionInFinder() {
        let urls = canonicalSelection().map { $0.url }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    struct VolumeInfo: Identifiable, Hashable {
        let id: URL
        let name: String
        let totalBytes: Int64
        let freeBytes: Int64
        let isRemovable: Bool
        let isInternal: Bool
    }

    // List all mounted local volumes. Excludes synthetic Apple read-only
    // overlay points the user can't usefully scan.
    func mountedVolumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeIsRemovableKey, .volumeIsInternalKey, .volumeIsBrowsableKey,
            .volumeIsLocalKey, .volumeIsRootFileSystemKey
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]) else { return [] }
        var out: [VolumeInfo] = []
        for url in urls {
            guard let rv = try? url.resourceValues(forKeys: Set(keys)),
                  rv.volumeIsBrowsable == true,
                  rv.volumeIsLocal == true else { continue }
            let name = rv.volumeName ?? url.lastPathComponent
            let total = Int64(rv.volumeTotalCapacity ?? 0)
            let free = Int64(rv.volumeAvailableCapacity ?? 0)
            out.append(VolumeInfo(
                id: url,
                name: name,
                totalBytes: total,
                freeBytes: free,
                isRemovable: rv.volumeIsRemovable ?? false,
                isInternal: rv.volumeIsInternal ?? false))
        }
        // Root volume first, then internal, then external/removable.
        return out.sorted { a, b in
            if a.id.path == "/" { return true }
            if b.id.path == "/" { return false }
            if a.isInternal != b.isInternal { return a.isInternal }
            return a.name < b.name
        }
    }

    private func removeNodeFromTree(_ node: FileNode) {
        guard let parent = node.parent else { return }
        let removedSize = node.totalSize
        let removedFiles = node.isDirectory ? node.fileCount : 1
        let removedDirs = node.isDirectory ? (1 + node.dirCount) : 0
        parent.children.removeAll { $0 === node }
        var p: FileNode? = parent
        while let cur = p {
            cur.totalSize -= removedSize
            cur.fileCount -= removedFiles
            cur.dirCount -= removedDirs
            p = cur.parent
        }
        if let r = root {
            legend = computeLegend(root: r)
            statusText = "\(r.fileCount.formatted()) files · \(r.dirCount.formatted()) folders · \(ByteFormatter.string(r.totalSize)) — \(r.url.path)"
        }
        selectedNodes.removeAll { $0 === node }
        if !selectedNodes.contains(where: { $0 === parent }) {
            selectedNodes.append(parent)
        }
        if zoomRoot === node { zoomRoot = parent }
        mutationToken += 1
    }

    private func captureVolumeInfo(scanRoot: URL) {
        let keys: Set<URLResourceKey> = [
            .volumeURLKey, .volumeNameKey,
            .volumeAvailableCapacityKey, .volumeTotalCapacityKey
        ]
        guard let rv = try? scanRoot.resourceValues(forKeys: keys) else {
            scanRootIsVolume = false
            volumeName = nil
            return
        }
        volumeName = rv.volumeName
        volumeFreeBytes = Int64(rv.volumeAvailableCapacity ?? 0)
        volumeTotalBytes = Int64(rv.volumeTotalCapacity ?? 0)
        // Treat the scan root as a volume scan only if it is the volume's
        // mount point, not just some folder that happens to live on it.
        if let volURL = rv.volume?.standardizedFileURL {
            scanRootIsVolume = volURL.path == scanRoot.standardizedFileURL.path
        } else {
            scanRootIsVolume = false
        }
    }

    private func computeLegend(root: FileNode) -> [(FileCategory, Int64)] {
        var sums: [FileCategory: Int64] = [:]
        var stack: [FileNode] = [root]
        while let n = stack.popLast() {
            if n.isDirectory {
                stack.append(contentsOf: n.children)
            } else {
                let cat = FileTypeClassifier.category(for: n)
                sums[cat, default: 0] += n.totalSize
            }
        }
        return sums.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            mainLayout
            // Overlay (not sheet): keeps the window's traffic lights live
            // so Cmd+W / red-button quit still work, and lets the AI setup
            // sheet stack above it without modal-on-modal limitations.
            if model.showWelcome {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { /* swallow */ }
                    .transition(.opacity)
                WelcomeView()
                    .environmentObject(model)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 8)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: model.showWelcome)
        .frame(minWidth: 1080, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $model.showAISetup) {
            AISetupView()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showAIChat) {
            AIChatView()
                .environmentObject(model)
        }
    }

    private var mainLayout: some View {
        VStack(spacing: 0) {
            Toolbar()
                .environmentObject(model)
            Divider()
            if model.isScanning {
                ProgressBar()
                    .environmentObject(model)
                Divider()
            }
            HSplitView {
                FileOutlineView(root: model.root,
                                selectedNodes: $model.selectedNodes,
                                mutationToken: model.mutationToken,
                                model: model)
                    .frame(minWidth: 260, idealWidth: 320)
                    .background(Color(nsColor: .controlBackgroundColor))

                TreemapView(root: model.root,
                            selectedNodes: $model.selectedNodes,
                            zoomRoot: $model.zoomRoot,
                            mutationToken: model.mutationToken,
                            model: model,
                            onDoubleClick: { node in
                                model.zoomIn(node)
                            })
                    .frame(minWidth: 360)

                SidePane()
                    .environmentObject(model)
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
            Divider()
            StatusBar()
                .environmentObject(model)
        }
    }
}

private struct Toolbar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            ToolbarButton(title: "Scan Folder", systemImage: "folder.badge.questionmark") {
                model.chooseAndScan()
            }
            .disabled(model.isScanning)

            ScanDiskMenu()
                .environmentObject(model)
                .disabled(model.isScanning)

            ToolbarButton(title: "Home", systemImage: "house.fill") {
                model.startScan(url: FileManager.default.homeDirectoryForCurrentUser)
            }
            .disabled(model.isScanning)

            Divider().frame(height: 22)

            ToolbarButton(title: "Zoom Out", systemImage: "minus.magnifyingglass") {
                model.zoomOut()
            }
            .disabled(model.root == nil)

            ToolbarButton(title: "Reset", systemImage: "arrow.uturn.backward") {
                model.resetZoom()
            }
            .disabled(model.root == nil)

            Divider().frame(height: 22)

            ToolbarButton(title: "Reveal", systemImage: "eye") {
                model.revealSelectionInFinder()
            }
            .disabled(!model.hasSelection)

            ToolbarButton(title: "Move to Trash", systemImage: "trash.fill",
                          tint: .red) {
                model.moveSelectionToTrash()
            }
            .disabled(!model.hasSelection
                      || model.canonicalSelection().allSatisfy { $0 === model.root })

            Spacer()

            ToolbarButton(title: model.aiConnected ? "Assistant" : "Connect AI",
                          systemImage: "sparkles",
                          tint: .purple,
                          highlighted: model.aiConnected) {
                if model.aiConnected {
                    model.showAIChat = true
                } else {
                    model.showAISetup = true
                }
            }

            ToolbarButton(title: "Preview",
                          systemImage: model.showPreview ? "sidebar.right" : "sidebar.right",
                          tint: model.showPreview ? .accentColor : .secondary,
                          highlighted: model.showPreview) {
                model.showPreview.toggle()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}

private struct ToolbarButton: View {
    let title: String
    let systemImage: String
    var tint: Color = .accentColor
    var highlighted: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(highlighted
                          ? Color.accentColor.opacity(0.18)
                          : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(highlighted
                                  ? Color.accentColor.opacity(0.6)
                                  : Color.primary.opacity(0.08),
                                  lineWidth: highlighted ? 1 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct StatusBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            if model.selectedNodes.count > 1 {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(.secondary)
                Text("\(model.selectedNodes.count) items selected")
                Text("·")
                    .foregroundStyle(.secondary)
                Text(ByteFormatter.string(model.selectionTotalSize))
                    .foregroundStyle(.secondary)
            } else if let sel = model.primarySelected, sel !== model.root {
                Image(systemName: sel.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundStyle(.secondary)
                Text(sel.url.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("·")
                    .foregroundStyle(.secondary)
                Text(ByteFormatter.string(sel.totalSize))
                    .foregroundStyle(.secondary)
            } else {
                Text(model.statusText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .font(.system(size: 11, weight: .regular, design: .rounded))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }
}

private struct ProgressBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Scanning…")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text("\(model.progressFiles.formatted()) files")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(ByteFormatter.string(model.progressBytes))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { model.cancelScan() }
                    .controlSize(.small)
            }
            ProgressView()
                .progressViewStyle(.linear)
                .controlSize(.small)
            Text(condensedPath(model.progressPath))
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func condensedPath(_ p: String) -> String {
        if p.isEmpty { return " " }
        return p
    }
}

private struct ScanDiskMenu: View {
    @EnvironmentObject var model: AppModel
    @State private var volumes: [AppModel.VolumeInfo] = []

    var body: some View {
        Menu {
            ForEach(volumes) { v in
                Button {
                    model.startScan(url: v.id)
                } label: {
                    let used = v.totalBytes - v.freeBytes
                    Text("\(v.name) — \(ByteFormatter.string(used)) used of \(ByteFormatter.string(v.totalBytes))")
                }
            }
            if volumes.isEmpty {
                Text("No volumes available")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Scan Disk")
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onAppear { volumes = model.mountedVolumes() }
        // Refresh the list whenever the menu is opened in case a volume was
        // mounted/unmounted since launch.
        .simultaneousGesture(TapGesture().onEnded {
            volumes = model.mountedVolumes()
        })
    }
}
