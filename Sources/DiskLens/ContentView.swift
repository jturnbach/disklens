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
    enum ChatPresentation: Equatable { case hidden, docked, floating }

    @Published var aiProvider: AIProvider? = nil
    @Published var aiModel: String = ""
    @Published var aiMessages: [ChatMessage] = []
    @Published var aiSending: Bool = false
    @Published var chatPresentation: ChatPresentation = .hidden
    @Published var showAISetup: Bool = false
    // The current chat input text. Lifted onto the model so context-menu
    // actions can prefill it without having to reach into the view's state.
    @Published var aiDraft: String = ""

    // The API key is read from Keychain ONCE on launch (or when the user
    // connects) and cached here. SwiftUI re-renders call `aiConnected` /
    // `aiClient` very frequently — on an ad-hoc signed app, every Keychain
    // read triggers an ACL prompt, which would pop the auth modal on every
    // scan progress tick. Cache + never hit Keychain from a view body.
    private var cachedAPIKey: String? = nil

    // Holds the floating NSWindow when the user pops the chat out. Kept on
    // the model so we can bring it to front or close it from anywhere.
    var floatingChatController: NSWindowController?

    func openAIChat() {
        if !aiConnected { showAISetup = true; return }
        if chatPresentation == .floating {
            floatingChatController?.window?.makeKeyAndOrderFront(nil)
        } else {
            chatPresentation = .docked
        }
    }

    func closeAIChat() {
        if chatPresentation == .floating {
            floatingChatController?.close()
            floatingChatController = nil
        }
        chatPresentation = .hidden
    }

    func popOutAIChat() {
        // Implemented in DiskLensApp.swift where it has access to the
        // NSHostingView + NSWindow creation helpers.
        ChatWindowHost.popOut(model: self)
    }

    func popInAIChat() {
        floatingChatController?.close()
        floatingChatController = nil
        chatPresentation = .docked
    }

    var aiClient: AIClient? {
        guard let provider = aiProvider,
              let key = cachedAPIKey, !key.isEmpty else { return nil }
        return AIClient(provider: provider,
                        apiKey: key,
                        model: aiModel.isEmpty ? provider.defaultModel : aiModel)
    }

    var aiConnected: Bool {
        aiProvider != nil && !(cachedAPIKey ?? "").isEmpty
    }

    // Persists which provider the user picked (the actual key lives in the
    // Keychain — we only store the provider id and model in defaults).
    private let activeProviderKey = "DiskLens.activeAIProvider"
    private let activeModelKey    = "DiskLens.activeAIModel"

    func loadAISettings() {
        // Called exactly once at launch. One Keychain read here is OK; the
        // user will see a single "Always Allow" prompt, grant it, and then
        // every subsequent check goes through the in-memory cache.
        guard let raw = UserDefaults.standard.string(forKey: activeProviderKey),
              let provider = AIProvider(rawValue: raw),
              let key = Keychain.load(account: provider.keychainAccount),
              !key.isEmpty else { return }
        aiProvider = provider
        cachedAPIKey = key
        aiModel = UserDefaults.standard.string(forKey: activeModelKey)
            ?? provider.defaultModel
    }

    func setAIProvider(_ provider: AIProvider, apiKey: String, model: String) throws {
        try Keychain.save(account: provider.keychainAccount, value: apiKey)
        aiProvider = provider
        cachedAPIKey = apiKey
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
        cachedAPIKey = nil
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
        let index = pathIndex
        Task { @MainActor in
            do {
                let reply = try await client.send(system: system, history: history)
                let (prose, suggestions) = SuggestionParser.parse(reply, pathIndex: index)
                aiMessages.append(ChatMessage(
                    role: .assistant,
                    content: prose,
                    suggestions: suggestions))
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

    // Prefills the chat input with a path-aware question about the given
    // nodes and opens the chat so the user can edit / confirm before
    // sending. Never auto-sends. If no provider is connected yet, jump to
    // setup first; the draft is still set so the user sees it after
    // finishing setup.
    func prefillChatPrompt(for targets: [FileNode]) {
        guard !targets.isEmpty else { return }
        aiDraft = buildAskPrompt(for: targets)
        if aiConnected {
            if chatPresentation == .hidden {
                chatPresentation = .docked
            } else if chatPresentation == .floating {
                floatingChatController?.window?.makeKeyAndOrderFront(nil)
            }
        } else {
            showAISetup = true
        }
    }

    private func buildAskPrompt(for targets: [FileNode]) -> String {
        func abbrev(_ path: String) -> String {
            NSString(string: path).abbreviatingWithTildeInPath
        }
        if targets.count == 1, let t = targets.first {
            let kind = t.isDirectory ? "folder" : "file"
            return "What is this \(kind) and is it safe to delete?\n\n`\(abbrev(t.url.path))` — \(ByteFormatter.string(t.totalSize))"
        }
        var lines: [String] = []
        lines.append("What are these items and which ones are safe to delete?")
        lines.append("")
        for t in targets.prefix(20) {
            lines.append("- `\(abbrev(t.url.path))` — \(ByteFormatter.string(t.totalSize))")
        }
        if targets.count > 20 {
            lines.append("- … and \(targets.count - 20) more")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Suggestion actions (from the chat's inline cards)

    private func findSuggestion(messageID: UUID,
                                suggestionID: UUID)
    -> (msgIdx: Int, sugIdx: Int)? {
        guard let mi = aiMessages.firstIndex(where: { $0.id == messageID }),
              let si = aiMessages[mi].suggestions.firstIndex(where: { $0.id == suggestionID })
        else { return nil }
        return (mi, si)
    }

    func trashSuggestion(messageID: UUID, suggestionID: UUID) {
        guard let loc = findSuggestion(messageID: messageID, suggestionID: suggestionID) else { return }
        var sug = aiMessages[loc.msgIdx].suggestions[loc.sugIdx]
        guard let ref = sug.nodeRef,
              let node = pathIndex[ref.path],
              node !== root else {
            sug.status = .failed("Not in current scan")
            aiMessages[loc.msgIdx].suggestions[loc.sugIdx] = sug
            return
        }

        // Preflight: reject obviously system-protected paths before even
        // hitting the file system, so the failure message is useful.
        if let reason = protectedPathReason(node.url.path) {
            sug.status = .failed(reason)
            aiMessages[loc.msgIdx].suggestions[loc.sugIdx] = sug
            return
        }
        do {
            var trashed: NSURL? = nil
            try FileManager.default.trashItem(at: node.url, resultingItemURL: &trashed)
            removeNodeFromTree(node)
            sug.status = .deleted
        } catch {
            sug.status = .failed(friendlyTrashError(error, path: node.url.path))
        }
        aiMessages[loc.msgIdx].suggestions[loc.sugIdx] = sug
    }

    // Retry a failed deletion with administrator privileges via osascript.
    // Shows the standard macOS admin password prompt; if accepted, moves
    // the file to ~/.Trash (so it's still recoverable) with `sudo mv`.
    func trashSuggestionAsAdmin(messageID: UUID, suggestionID: UUID) {
        guard let loc = findSuggestion(messageID: messageID, suggestionID: suggestionID) else { return }
        var sug = aiMessages[loc.msgIdx].suggestions[loc.sugIdx]
        guard let ref = sug.nodeRef,
              let node = pathIndex[ref.path] else {
            sug.status = .failed("Not in current scan")
            aiMessages[loc.msgIdx].suggestions[loc.sugIdx] = sug
            return
        }

        let path = node.url.path
        let result = AdminElevation.moveToUserTrash(path: path,
                                                     reason: "delete system-protected file")

        switch result {
        case .success:
            removeNodeFromTree(node)
            sug.status = .deleted
        case .cancelled:
            sug.status = .failed("Cancelled admin authorization")
        case .failure(let msg):
            sug.status = .failed("Admin delete failed: \(msg)")
        }
        aiMessages[loc.msgIdx].suggestions[loc.sugIdx] = sug
    }

    // Only the truly untouchable prefixes are rejected preflight. Other
    // protected locations (e.g. /Library/Application Support) fall through
    // to trashItem and, on permission failure, get offered the admin-retry
    // path.
    private func protectedPathReason(_ path: String) -> String? {
        let hardBlocks: [(String, String)] = [
            ("/System/",      "Protected by macOS System Integrity Protection"),
            ("/private/var/vm/", "Active swap / VM file — macOS manages this automatically"),
            ("/bin/",         "Protected system path"),
            ("/sbin/",        "Protected system path"),
            ("/usr/bin/",     "Protected system path"),
            ("/usr/sbin/",    "Protected system path"),
            ("/usr/libexec/", "Protected system path"),
        ]
        for (prefix, reason) in hardBlocks {
            if path.hasPrefix(prefix) { return reason }
        }
        return nil
    }

    private func friendlyTrashError(_ error: Error, path: String) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return "File no longer exists"
            case NSFileWriteNoPermissionError:
                return "Permission denied. Grant DiskLens Full Disk Access in System Settings to delete files in protected locations."
            case NSFileWriteOutOfSpaceError:
                return "Disk is full — cannot move to Trash"
            case NSFileWriteVolumeReadOnlyError:
                return "Volume is read-only"
            default:
                break
            }
        }
        // POSIX errors surfaced through the bridge use NSPOSIXErrorDomain.
        if ns.domain == NSPOSIXErrorDomain {
            switch ns.code {
            case Int(EACCES), Int(EPERM):
                return "Permission denied. Grant DiskLens Full Disk Access in System Settings to delete files in protected locations."
            case Int(ENOENT):
                return "File no longer exists"
            case Int(EROFS):
                return "Volume is read-only"
            default:
                break
            }
        }
        return ns.localizedDescription
    }

    func skipSuggestion(messageID: UUID, suggestionID: UUID) {
        guard let loc = findSuggestion(messageID: messageID, suggestionID: suggestionID) else { return }
        aiMessages[loc.msgIdx].suggestions[loc.sugIdx].status = .skipped
    }

    func revealSuggestion(messageID: UUID, suggestionID: UUID) {
        guard let loc = findSuggestion(messageID: messageID, suggestionID: suggestionID),
              let ref = aiMessages[loc.msgIdx].suggestions[loc.sugIdx].nodeRef,
              let node = pathIndex[ref.path] else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    func trashAllPendingSuggestions(messageID: UUID) {
        guard let mi = aiMessages.firstIndex(where: { $0.id == messageID }) else { return }
        let pending = aiMessages[mi].suggestions.enumerated()
            .filter { $0.element.status == .pending && $0.element.isResolved }
        // Confirm once for the whole batch.
        let totalBytes = pending.reduce(Int64(0)) { $0 + $1.element.resolvedSize }
        let alert = NSAlert()
        alert.messageText = "Move \(pending.count) items to Trash?"
        alert.informativeText = "\(ByteFormatter.string(totalBytes)) total. Suggested by the AI assistant."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Trash deepest paths first so parents don't remove children under
        // us before we can mark them.
        let ordered = pending.sorted {
            $0.element.nodeRef?.path.count ?? 0 > $1.element.nodeRef?.path.count ?? 0
        }
        for (si, _) in ordered {
            let sugID = aiMessages[mi].suggestions[si].id
            trashSuggestion(messageID: messageID, suggestionID: sugID)
        }
    }

    func skipAllPendingSuggestions(messageID: UUID) {
        guard let mi = aiMessages.firstIndex(where: { $0.id == messageID }) else { return }
        for i in aiMessages[mi].suggestions.indices where aiMessages[mi].suggestions[i].status == .pending {
            aiMessages[mi].suggestions[i].status = .skipped
        }
    }

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

    // Absolute-path → node lookup, rebuilt after each scan and kept in sync
    // as nodes are trashed. Used by the AI assistant to resolve a model-
    // emitted path back to a real FileNode for interactive delete cards.
    var pathIndex: [String: FileNode] = [:]

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
                self.rebuildPathIndex()
            } else {
                self.statusText = "Scan cancelled."
                self.pathIndex = [:]
            }
        })
    }

    func cancelScan() {
        scanner.cancel()
    }

    // Incremental refresh: walks the existing tree and only re-enumerates
    // directories whose mtime changed. Unchanged subtrees skip the readdir
    // entirely, so this is far cheaper than a fresh scan when most of the
    // disk hasn't changed since the last scan.
    func rescan() {
        guard let r = root else { return }
        isScanning = true
        progressFiles = 0
        progressBytes = 0
        statusText = "Refreshing \(r.url.path)…"
        scanner.refresh(root: r, progress: { [weak self] p in
            guard let self else { return }
            self.progressFiles = p.filesScanned
            self.progressBytes = p.bytesScanned
            self.progressPath = p.currentPath
        }, completion: { [weak self] ok in
            guard let self else { return }
            self.isScanning = false
            guard ok, let r = self.root else {
                self.statusText = "Refresh cancelled."
                return
            }
            self.legend = self.computeLegend(root: r)
            self.captureVolumeInfo(scanRoot: r.url)
            self.rebuildPathIndex()
            // Prune any selected nodes that no longer exist in the tree.
            self.selectedNodes = self.selectedNodes.filter { node in
                self.pathIndex[node.url.path] === node
            }
            self.mutationToken += 1
            self.statusText = "\(r.fileCount.formatted()) files · \(r.dirCount.formatted()) folders · \(ByteFormatter.string(r.totalSize)) — \(r.url.path)"
        })
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
        // Drop the removed subtree from the path index so stale pointers
        // don't survive in later AI suggestion lookups.
        var stack: [FileNode] = [node]
        while let n = stack.popLast() {
            pathIndex.removeValue(forKey: n.url.path)
            if n.isDirectory { stack.append(contentsOf: n.children) }
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

    private func rebuildPathIndex() {
        var idx: [String: FileNode] = [:]
        guard let r = root else { pathIndex = [:]; return }
        var stack: [FileNode] = [r]
        while let n = stack.popLast() {
            idx[n.url.path] = n
            if n.isDirectory { stack.append(contentsOf: n.children) }
        }
        pathIndex = idx
    }

    private func captureVolumeInfo(scanRoot: URL) {
        // We ask for the "important usage" free capacity (which folds in
        // purgeable cache that macOS can evict on demand) — this matches
        // what About This Mac shows. Falling back to the plain available
        // capacity if the OS doesn't return the newer key.
        let keys: Set<URLResourceKey> = [
            .volumeURLKey, .volumeNameKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey
        ]
        guard let rv = try? scanRoot.resourceValues(forKeys: keys) else {
            scanRootIsVolume = false
            volumeName = nil
            return
        }
        volumeName = rv.volumeName
        let importantFree = rv.volumeAvailableCapacityForImportantUsage ?? 0
        let plainFree = Int64(rv.volumeAvailableCapacity ?? 0)
        volumeFreeBytes = importantFree > 0 ? Int64(importantFree) : plainFree
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

                if model.chatPresentation == .docked {
                    AIChatView()
                        .environmentObject(model)
                        .frame(minWidth: 340, idealWidth: 400, maxWidth: 560)
                        .background(Color(nsColor: .windowBackgroundColor))
                }
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
            ScanMenu()
                .environmentObject(model)
                .disabled(model.isScanning)

            ToolbarButton(title: "Home", systemImage: "house.fill") {
                model.startScan(url: FileManager.default.homeDirectoryForCurrentUser)
            }
            .disabled(model.isScanning)

            ToolbarButton(title: "Refresh", systemImage: "arrow.clockwise") {
                model.rescan()
            }
            .disabled(model.isScanning || model.root == nil)

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
                          highlighted: model.chatPresentation != .hidden) {
                if !model.aiConnected {
                    model.showAISetup = true
                } else if model.chatPresentation == .docked {
                    model.closeAIChat()
                } else {
                    model.openAIChat()
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

// Shared "chip" pill style used for every toolbar control. Both
// ToolbarButton (regular Button) and ScanMenu (Menu wrapper) render their
// label through this modifier so the two control flavors are guaranteed
// pixel-identical.
struct ToolbarChip: ViewModifier {
    var highlighted: Bool = false

    func body(content: Content) -> some View {
        content
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
}

extension View {
    func toolbarChip(highlighted: Bool = false) -> some View {
        self.modifier(ToolbarChip(highlighted: highlighted))
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
            .toolbarChip(highlighted: highlighted)
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

private struct ScanMenu: View {
    @EnvironmentObject var model: AppModel
    @State private var volumes: [AppModel.VolumeInfo] = []

    var body: some View {
        Menu {
            Button {
                model.chooseAndScan()
            } label: {
                Label("Choose Folder…", systemImage: "folder.badge.questionmark")
            }

            if !volumes.isEmpty {
                Divider()
                Section("Disks") {
                    ForEach(volumes) { v in
                        Button {
                            model.startScan(url: v.id)
                        } label: {
                            let used = v.totalBytes - v.freeBytes
                            Label("\(v.name) — \(ByteFormatter.string(used)) used of \(ByteFormatter.string(v.totalBytes))",
                                  systemImage: v.isRemovable
                                    ? "externaldrive.fill"
                                    : "internaldrive.fill")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Scan")
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .toolbarChip()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onAppear { volumes = model.mountedVolumes() }
        .simultaneousGesture(TapGesture().onEnded {
            volumes = model.mountedVolumes()
        })
    }
}
