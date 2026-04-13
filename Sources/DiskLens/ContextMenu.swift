import AppKit
import Foundation

// AppKit menus use target/action selectors. NSMenuItem.target is a *weak*
// reference, so any external trampoline object must be retained somewhere
// else for the lifetime of the menu — fragile. This subclass instead stores
// the closure on the item itself and uses self as its own target. NSMenu
// strongly retains its items, so the closure can't be garbage-collected
// before the click fires.
final class ClosureMenuItem: NSMenuItem {
    private let closure: () -> Void

    init(title: String, image: NSImage?, enabled: Bool,
         keyEquivalent: String, closure: @escaping () -> Void) {
        self.closure = closure
        super.init(title: title,
                   action: #selector(invoke(_:)),
                   keyEquivalent: keyEquivalent)
        self.target = self
        self.image = image
        self.isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc func invoke(_ sender: Any?) { closure() }
}

enum NodeContextMenu {
    @MainActor
    static func build(for node: FileNode, model: AppModel) -> NSMenu {
        let menu = NSMenu(title: "")
        menu.autoenablesItems = false

        // Operate on the multi-selection if the right-clicked node belongs
        // to it; otherwise act on the single clicked node.
        let isInSelection = model.selectedNodes.contains(where: { $0 === node })
        let targets: [FileNode] = isInSelection
            ? model.canonicalSelection()
            : [node]
        let isMulti = targets.count > 1
        let urls = targets.map { $0.url }
        let totalBytes = targets.reduce(0) { $0 + $1.totalSize }

        func add(_ title: String,
                 icon: String? = nil,
                 enabled: Bool = true,
                 keyEquivalent: String = "",
                 action: @escaping () -> Void) {
            let img = icon.flatMap {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil)
            }
            let item = ClosureMenuItem(title: title,
                                       image: img,
                                       enabled: enabled,
                                       keyEquivalent: keyEquivalent,
                                       closure: action)
            menu.addItem(item)
        }

        let isRoot = (targets.count == 1 && targets[0] === model.root)
        let allDirs = targets.allSatisfy { $0.isDirectory }

        // Header — describes what the menu will act on.
        let headerTitle = isMulti
            ? "\(targets.count) items — \(ByteFormatter.string(totalBytes))"
            : "\(node.name) — \(ByteFormatter.string(node.totalSize))"
        let header = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        add(isMulti ? "Open All" : "Open", icon: "arrow.up.forward.app") {
            for u in urls { NSWorkspace.shared.open(u) }
        }

        add("Quick Look", icon: "eye", keyEquivalent: " ") {
            quickLook(urls: urls)
        }

        add(isMulti ? "Reveal in Finder" : "Reveal in Finder",
            icon: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }

        add("Show in Terminal", icon: "terminal", enabled: !isMulti) {
            if let first = urls.first { showInTerminal(url: first) }
        }

        menu.addItem(NSMenuItem.separator())

        let askTitle = isMulti
            ? "Ask AI about these \(targets.count) items…"
            : "Ask AI…"
        add(askTitle, icon: "sparkles") {
            model.prefillChatPrompt(for: targets)
        }

        menu.addItem(NSMenuItem.separator())

        add(isMulti ? "Copy \(targets.count) Paths" : "Copy Path",
            icon: "doc.on.clipboard") {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(urls.map { $0.path }.joined(separator: "\n"),
                         forType: .string)
        }

        add(isMulti ? "Copy \(targets.count) Names" : "Copy Name",
            icon: "textformat") {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(targets.map { $0.name }.joined(separator: "\n"),
                         forType: .string)
        }

        if !isMulti && allDirs {
            add("Zoom Treemap to Here",
                icon: "plus.magnifyingglass",
                enabled: !isRoot || model.zoomRoot !== node) {
                model.zoomIn(node)
            }
        }

        menu.addItem(NSMenuItem.separator())

        let trashTitle = isMulti
            ? "Move \(targets.count) Items to Trash"
            : "Move to Trash"
        add(trashTitle, icon: "trash", enabled: !isRoot) {
            // Make sure the model's selection matches what the user clicked
            // so moveSelectionToTrash acts on the right set.
            if !isInSelection {
                model.selectedNodes = [node]
            }
            model.moveSelectionToTrash()
        }

        return menu
    }

    private static func quickLook(urls: [URL]) {
        guard !urls.isEmpty else { return }
        // qlmanage ships with macOS and pops a Quick Look window. Passing
        // multiple paths lets the user page through them with arrow keys.
        let task = Process()
        task.launchPath = "/usr/bin/qlmanage"
        task.arguments = ["-p"] + urls.map { $0.path }
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try? task.run()
    }

    private static func showInTerminal(url: URL) {
        // Open Terminal at the directory; for a file, open at its parent.
        var rv = url
        let isDir = (try? rv.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if !isDir { rv = rv.deletingLastPathComponent() }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let cfg = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([rv], withApplicationAt: terminal,
                                 configuration: cfg, completionHandler: nil)
    }
}
