import SwiftUI
import AppKit

// NSOutlineView wrapper. SwiftUI's List/OutlineGroup does not scale to the
// hundreds of thousands of nodes we get from real-world directory scans.
struct FileOutlineView: NSViewRepresentable {
    let root: FileNode?
    @Binding var selectedNodes: [FileNode]
    let mutationToken: Int
    unowned let model: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let outline = ContextMenuOutlineView()
        outline.model = model
        outline.style = .inset
        outline.usesAlternatingRowBackgroundColors = true
        outline.rowSizeStyle = .small
        outline.headerView = NSTableHeaderView()
        outline.allowsColumnReordering = false
        outline.allowsColumnResizing = true
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.autoresizesOutlineColumn = false
        outline.indentationPerLevel = 14
        outline.backgroundColor = .clear

        // Columns
        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = "Name"
        nameCol.width = 240
        nameCol.minWidth = 120
        nameCol.resizingMask = [.userResizingMask]
        outline.addTableColumn(nameCol)
        outline.outlineTableColumn = nameCol

        let sizeCol = NSTableColumn(identifier: .init("size"))
        sizeCol.title = "Size"
        sizeCol.width = 80
        sizeCol.minWidth = 60
        sizeCol.resizingMask = [.userResizingMask]
        outline.addTableColumn(sizeCol)

        let pctCol = NSTableColumn(identifier: .init("pct"))
        pctCol.title = "Percent"
        pctCol.width = 90
        pctCol.minWidth = 60
        pctCol.resizingMask = [.userResizingMask]
        outline.addTableColumn(pctCol)

        let itemsCol = NSTableColumn(identifier: .init("items"))
        itemsCol.title = "Items"
        itemsCol.width = 60
        itemsCol.minWidth = 40
        itemsCol.resizingMask = [.userResizingMask]
        outline.addTableColumn(itemsCol)

        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        context.coordinator.outline = outline

        scroll.documentView = outline
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let outline = nsView.documentView as? NSOutlineView else { return }
        let coord = context.coordinator
        let rootChanged = coord.root !== root
        let mutated = coord.lastMutationToken != mutationToken
        if rootChanged {
            coord.root = root
            coord.lastMutationToken = mutationToken
            outline.reloadData()
            if let r = root {
                outline.expandItem(r)
                if let big = r.children.first, big.isDirectory {
                    outline.expandItem(big)
                }
            }
        } else if mutated {
            coord.lastMutationToken = mutationToken
            outline.reloadData()
            if let r = root { outline.expandItem(r) }
        }
        coord.parent = self

        // Sync selection from the binding (e.g. treemap click). We compare
        // the desired row set to the current one; if they already match we
        // skip the call to avoid feedback loops with selectionDidChange.
        let desired = IndexSet(selectedNodes.compactMap { node -> Int? in
            coord.expandTo(node, in: outline)
            let r = outline.row(forItem: node)
            return r >= 0 ? r : nil
        })
        if desired != outline.selectedRowIndexes {
            coord.suppressSelectionCallback = true
            outline.selectRowIndexes(desired, byExtendingSelection: false)
            coord.suppressSelectionCallback = false
            if let first = desired.first { outline.scrollRowToVisible(first) }
        }
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: FileOutlineView
        weak var outline: NSOutlineView?
        var root: FileNode?
        var lastMutationToken: Int = -1
        var suppressSelectionCallback: Bool = false

        init(_ parent: FileOutlineView) {
            self.parent = parent
        }

        // Walk parents and expand each ancestor so a deep node becomes visible.
        func expandTo(_ node: FileNode, in outline: NSOutlineView) {
            var chain: [FileNode] = []
            var p = node.parent
            while let cur = p {
                chain.append(cur)
                p = cur.parent
            }
            for n in chain.reversed() { outline.expandItem(n) }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if item == nil {
                return root == nil ? 0 : 1
            }
            guard let node = item as? FileNode else { return 0 }
            return node.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if item == nil { return root! }
            let node = item as! FileNode
            return node.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? FileNode else { return false }
            return node.isDirectory && !node.children.isEmpty
        }

        func outlineView(_ outlineView: NSOutlineView,
                         viewFor tableColumn: NSTableColumn?,
                         item: Any) -> NSView? {
            guard let node = item as? FileNode, let col = tableColumn else { return nil }
            let id = NSUserInterfaceItemIdentifier("cell-\(col.identifier.rawValue)")
            let cell: NSTableCellView
            if let reused = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = id
                let tf = NSTextField(labelWithString: "")
                tf.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                tf.lineBreakMode = .byTruncatingTail
                tf.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(tf)
                cell.textField = tf

                if col.identifier.rawValue == "name" {
                    let icon = NSImageView()
                    icon.translatesAutoresizingMaskIntoConstraints = false
                    icon.imageScaling = .scaleProportionallyDown
                    cell.addSubview(icon)
                    cell.imageView = icon
                    NSLayoutConstraint.activate([
                        icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 0),
                        icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                        icon.widthAnchor.constraint(equalToConstant: 16),
                        icon.heightAnchor.constraint(equalToConstant: 16),
                        tf.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
                        tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                        tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    ])
                } else {
                    NSLayoutConstraint.activate([
                        tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                        tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                        tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    ])
                }
            }

            switch col.identifier.rawValue {
            case "name":
                cell.textField?.stringValue = node.name
                let img: NSImage
                if node.isDirectory {
                    img = NSImage(systemSymbolName: "folder.fill",
                                  accessibilityDescription: "Folder")
                        ?? NSImage()
                    img.isTemplate = true
                } else {
                    img = NSWorkspace.shared.icon(forFile: node.url.path)
                    img.size = NSSize(width: 16, height: 16)
                }
                cell.imageView?.image = img
                if node.isDirectory {
                    cell.imageView?.contentTintColor = .systemBlue
                }
            case "size":
                cell.textField?.stringValue = ByteFormatter.string(node.totalSize)
                cell.textField?.alignment = .right
            case "pct":
                let totalRoot = root?.totalSize ?? 1
                let pct = totalRoot > 0
                    ? Double(node.totalSize) / Double(totalRoot) * 100
                    : 0
                cell.textField?.stringValue = String(format: "%.1f%%", pct)
                cell.textField?.alignment = .right
            case "items":
                if node.isDirectory {
                    cell.textField?.stringValue = "\(node.fileCount)"
                } else {
                    cell.textField?.stringValue = "—"
                }
                cell.textField?.alignment = .right
            default: break
            }
            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !suppressSelectionCallback,
                  let outline = outline else { return }
            let nodes = outline.selectedRowIndexes
                .compactMap { outline.item(atRow: $0) as? FileNode }
            // Only push if it actually changed — equal-by-identity check.
            let same = nodes.count == parent.selectedNodes.count
                && zip(nodes, parent.selectedNodes).allSatisfy { $0 === $1 }
            if !same {
                DispatchQueue.main.async { self.parent.selectedNodes = nodes }
            }
        }
    }
}

// NSOutlineView subclass that builds a context menu for the right-clicked
// row, overriding the default selection-based menu so right-click on a row
// targets that row even if it isn't the active selection.
final class ContextMenuOutlineView: NSOutlineView {
    weak var model: AppModel?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0, let node = self.item(atRow: row) as? FileNode,
              let model = model else { return nil }
        // Match Finder behavior: if the clicked row is already part of the
        // selection, leave the multi-selection intact; otherwise switch the
        // selection to just this row.
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return NodeContextMenu.build(for: node, model: model)
    }
}
