import Foundation
import SwiftUI

// A laid-out rectangle in the treemap — references the source file node so the
// view can highlight it and route clicks back to the selection model.
struct TreemapRect {
    var rect: CGRect
    var node: FileNode
    var depth: Int
}

// Squarified treemap layout (Bruls, Huijing, van Wijk 1999). Input nodes must
// be sorted largest-first; zero-size nodes are skipped.
enum SquarifiedTreemap {
    static func layout(root: FileNode,
                       in bounds: CGRect,
                       maxDepth: Int = 12) -> [TreemapRect] {
        var out: [TreemapRect] = []
        guard root.totalSize > 0, bounds.width > 1, bounds.height > 1 else {
            return out
        }
        layoutNode(root, rect: bounds, depth: 0, maxDepth: maxDepth, out: &out)
        return out
    }

    private static func layoutNode(_ node: FileNode,
                                   rect: CGRect,
                                   depth: Int,
                                   maxDepth: Int,
                                   out: inout [TreemapRect]) {
        if rect.width < 1 || rect.height < 1 { return }

        // Collapse packages / leaf dirs: emit directly as one tile.
        if !node.isDirectory || depth >= maxDepth || node.children.isEmpty {
            out.append(TreemapRect(rect: rect, node: node, depth: depth))
            return
        }

        // No inter-group padding: sibling groups should butt up against each
        // other, WinDirStat-style. Per-tile borders alone provide visual
        // separation between leaves.
        let inner = rect

        let items = node.children.filter { $0.totalSize > 0 }
        if items.isEmpty {
            out.append(TreemapRect(rect: rect, node: node, depth: depth))
            return
        }

        let total = items.reduce(Int64(0)) { $0 + $1.totalSize }
        if total <= 0 {
            out.append(TreemapRect(rect: rect, node: node, depth: depth))
            return
        }

        // Scale sizes to pixels: item.size * area / total.
        let scale = Double(inner.width) * Double(inner.height) / Double(total)
        let weighted: [(FileNode, Double)] = items.map {
            ($0, Double($0.totalSize) * scale)
        }

        var remaining = weighted
        var current = inner
        while !remaining.isEmpty {
            let (row, rest, rowRect, nextRect) = takeRow(from: remaining,
                                                         in: current)
            layoutRow(row, in: rowRect, depth: depth + 1,
                      maxDepth: maxDepth, out: &out)
            remaining = rest
            current = nextRect
        }
    }

    // Greedily extend a row while aspect ratios improve; return the placed row,
    // the remainder, the sub-rect consumed, and the leftover rect for the rest.
    private static func takeRow(from items: [(FileNode, Double)],
                                in rect: CGRect)
    -> ([(FileNode, Double)], [(FileNode, Double)], CGRect, CGRect) {
        let shortSide = min(rect.width, rect.height)
        var row: [(FileNode, Double)] = []
        var rowSum: Double = 0
        var i = 0
        while i < items.count {
            let next = items[i]
            let newSum = rowSum + next.1
            let newWorst = worst(row + [next], sum: newSum, side: shortSide)
            let oldWorst = worst(row, sum: rowSum, side: shortSide)
            if row.isEmpty || newWorst <= oldWorst {
                row.append(next)
                rowSum = newSum
                i += 1
            } else { break }
        }

        let rowArea = rowSum
        // Row thickness perpendicular to the short side.
        let thickness: CGFloat
        let rowRect: CGRect
        let nextRect: CGRect
        if rect.width <= rect.height {
            thickness = CGFloat(rowArea / Double(rect.width))
            let t = min(thickness, rect.height)
            rowRect = CGRect(x: rect.minX, y: rect.minY,
                             width: rect.width, height: t)
            nextRect = CGRect(x: rect.minX, y: rect.minY + t,
                              width: rect.width, height: max(0, rect.height - t))
        } else {
            thickness = CGFloat(rowArea / Double(rect.height))
            let t = min(thickness, rect.width)
            rowRect = CGRect(x: rect.minX, y: rect.minY,
                             width: t, height: rect.height)
            nextRect = CGRect(x: rect.minX + t, y: rect.minY,
                              width: max(0, rect.width - t), height: rect.height)
        }
        let rest = Array(items[i...])
        return (row, rest, rowRect, nextRect)
    }

    private static func worst(_ row: [(FileNode, Double)],
                               sum: Double,
                               side: CGFloat) -> Double {
        if row.isEmpty || sum <= 0 { return .greatestFiniteMagnitude }
        var mx: Double = 0, mn: Double = .greatestFiniteMagnitude
        for (_, a) in row { mx = max(mx, a); mn = min(mn, a) }
        let s2 = sum * sum
        let w2 = Double(side) * Double(side)
        return max(w2 * mx / s2, s2 / (w2 * mn))
    }

    private static func layoutRow(_ row: [(FileNode, Double)],
                                  in rowRect: CGRect,
                                  depth: Int,
                                  maxDepth: Int,
                                  out: inout [TreemapRect]) {
        let sum = row.reduce(0.0) { $0 + $1.1 }
        guard sum > 0 else { return }
        let horizontal = rowRect.width >= rowRect.height
        if horizontal {
            var x = rowRect.minX
            for (node, area) in row {
                let w = CGFloat(area / Double(rowRect.height))
                let r = CGRect(x: x, y: rowRect.minY,
                               width: max(0, w), height: rowRect.height)
                layoutNode(node, rect: r, depth: depth,
                           maxDepth: maxDepth, out: &out)
                x += w
            }
        } else {
            var y = rowRect.minY
            for (node, area) in row {
                let h = CGFloat(area / Double(rowRect.width))
                let r = CGRect(x: rowRect.minX, y: y,
                               width: rowRect.width, height: max(0, h))
                layoutNode(node, rect: r, depth: depth,
                           maxDepth: maxDepth, out: &out)
                y += h
            }
        }
    }
}

// The TreemapView now renders the treemap to a CGImage via TreemapRenderer
// and hands that image to a CALayer-backed NSView. During live window
// resize the CALayer stretches the cached pixels on the GPU — SwiftUI
// does zero drawing per frame.
struct TreemapView: View {
    let root: FileNode?
    @Binding var selectedNodes: [FileNode]
    @Binding var zoomRoot: FileNode?
    let mutationToken: Int
    unowned let model: AppModel
    var onDoubleClick: (FileNode) -> Void

    @StateObject private var renderer = TreemapRenderer()
    @State private var hovered: FileNode? = nil

    var body: some View {
        GeometryReader { geo in
            let displayRoot = zoomRoot ?? root

            ZStack(alignment: .topLeading) {
                // Base treemap bitmap. Scales natively via CALayer; no
                // SwiftUI redraws on resize.
                TreemapLayerView(image: renderer.image)
                    .allowsHitTesting(false)

                // Lightweight selection + dim overlay. Only touches the
                // selected subset — cheap.
                SelectionOverlay(selectedNodes: selectedNodes,
                                 cachedRects: renderer.cachedRects,
                                 cachedLayoutSize: renderer.cachedLayoutSize,
                                 currentSize: geo.size)
                    .allowsHitTesting(false)

                // Hit layer. Scales click coordinates lazily — zero
                // allocations per resize frame.
                HitLayer(rects: renderer.cachedRects,
                         logicalSize: renderer.cachedLayoutSize,
                         currentSize: geo.size,
                         model: model,
                         onClick: { node, mods in
                             if mods.contains(.command) || mods.contains(.shift) {
                                 if let idx = selectedNodes.firstIndex(where: { $0 === node }) {
                                     selectedNodes.remove(at: idx)
                                 } else {
                                     selectedNodes.append(node)
                                 }
                             } else {
                                 selectedNodes = [node]
                             }
                         },
                         onDoubleClick: onDoubleClick,
                         onHover: { hovered = $0 })
            }
            .background(Color(red: 0.08, green: 0.08, blue: 0.10))
            .overlay(alignment: .bottomLeading) {
                if let h = hovered {
                    Text(tooltipText(h))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.black.opacity(0.75))
                        )
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .onAppear {
                renderer.requestLayout(root: displayRoot,
                                       size: geo.size,
                                       mutationToken: mutationToken,
                                       immediate: true)
            }
            .onChange(of: geo.size) { newSize in
                renderer.requestLayout(root: displayRoot,
                                       size: newSize,
                                       mutationToken: mutationToken,
                                       immediate: false)
            }
            .onChange(of: mutationToken) { newToken in
                renderer.requestLayout(root: displayRoot,
                                       size: geo.size,
                                       mutationToken: newToken,
                                       immediate: true)
            }
            .onChange(of: displayRoot.map { ObjectIdentifier($0) }) { _ in
                renderer.requestLayout(root: displayRoot,
                                       size: geo.size,
                                       mutationToken: mutationToken,
                                       immediate: true)
            }
        }
    }

    private func tooltipText(_ n: FileNode) -> String {
        "\(n.name)  ·  \(ByteFormatter.string(n.totalSize))"
    }
}

// Dim + selection-outline overlay. Walks only the selected nodes' subtree
// once to compute a bounding box per selected directory, then draws in a
// SwiftUI Canvas scaled to current bounds. Handful of shapes — fast.
private struct SelectionOverlay: View {
    let selectedNodes: [FileNode]
    let cachedRects: [TreemapRect]
    let cachedLayoutSize: CGSize
    let currentSize: CGSize

    var body: some View {
        if selectedNodes.isEmpty
            || cachedLayoutSize.width < 1
            || cachedLayoutSize.height < 1 {
            Color.clear
        } else {
            Canvas { ctx, size in
                let sx = size.width / cachedLayoutSize.width
                let sy = size.height / cachedLayoutSize.height
                let highlightBoxes = dirBoundingBoxes(scaleX: sx, scaleY: sy)
                let fileTileRects = fileSelectionRects(scaleX: sx, scaleY: sy)

                // Dim the non-highlighted area with an even-odd punched
                // path — single fill, no iteration over all tiles.
                if !highlightBoxes.isEmpty {
                    var dim = Path()
                    dim.addRect(CGRect(origin: .zero, size: size))
                    for b in highlightBoxes { dim.addRect(b) }
                    ctx.fill(dim,
                             with: .color(Color.black.opacity(0.55)),
                             style: FillStyle(eoFill: true))
                }

                // Bright outline around each selected directory box.
                for b in highlightBoxes {
                    let path = Path(roundedRect: b.insetBy(dx: 0.5, dy: 0.5),
                                    cornerRadius: 1)
                    ctx.stroke(path, with: .color(.black), lineWidth: 3)
                    ctx.stroke(path, with: .color(.white), lineWidth: 1.5)
                }

                // Per-file outline for file selections.
                for r in fileTileRects {
                    let path = Path(roundedRect: r.insetBy(dx: 0.5, dy: 0.5),
                                    cornerRadius: 1)
                    ctx.stroke(path, with: .color(.white), lineWidth: 2)
                    ctx.stroke(path, with: .color(.black), lineWidth: 0.5)
                }
            }
        }
    }

    // Union of all descendant rects for each selected directory, already
    // scaled to current bounds.
    private func dirBoundingBoxes(scaleX: CGFloat,
                                   scaleY: CGFloat) -> [CGRect] {
        var out: [CGRect] = []
        for dir in selectedNodes where dir.isDirectory {
            let descIds = subtreeIds(of: dir)
            var box: CGRect? = nil
            for tr in cachedRects where descIds.contains(ObjectIdentifier(tr.node)) {
                box = box?.union(tr.rect) ?? tr.rect
            }
            if let b = box {
                out.append(CGRect(x: b.minX * scaleX,
                                  y: b.minY * scaleY,
                                  width: b.width * scaleX,
                                  height: b.height * scaleY))
            }
        }
        return out
    }

    private func fileSelectionRects(scaleX: CGFloat,
                                     scaleY: CGFloat) -> [CGRect] {
        let ids = Set(selectedNodes
            .filter { !$0.isDirectory }
            .map { ObjectIdentifier($0) })
        guard !ids.isEmpty else { return [] }
        return cachedRects
            .filter { !$0.node.isDirectory && ids.contains(ObjectIdentifier($0.node)) }
            .map {
                CGRect(x: $0.rect.minX * scaleX,
                       y: $0.rect.minY * scaleY,
                       width: $0.rect.width * scaleX,
                       height: $0.rect.height * scaleY)
            }
    }

    private func subtreeIds(of node: FileNode) -> Set<ObjectIdentifier> {
        var s = Set<ObjectIdentifier>()
        var stack: [FileNode] = [node]
        while let n = stack.popLast() {
            s.insert(ObjectIdentifier(n))
            if n.isDirectory { stack.append(contentsOf: n.children) }
        }
        return s
    }
}

// Transparent NSView that handles mouse events. SwiftUI's onTapGesture is
// per-shape, which would be catastrophic for huge treemaps.
struct HitLayer: NSViewRepresentable {
    let rects: [TreemapRect]
    let logicalSize: CGSize
    let currentSize: CGSize
    unowned let model: AppModel
    let onClick: (FileNode, NSEvent.ModifierFlags) -> Void
    let onDoubleClick: (FileNode) -> Void
    let onHover: (FileNode?) -> Void

    func makeNSView(context: Context) -> HitNSView {
        let v = HitNSView()
        v.rects = rects
        v.logicalSize = logicalSize
        v.currentSize = currentSize
        v.model = model
        v.onClick = onClick
        v.onDoubleClick = onDoubleClick
        v.onHover = onHover
        return v
    }

    func updateNSView(_ view: HitNSView, context: Context) {
        view.rects = rects
        view.logicalSize = logicalSize
        view.currentSize = currentSize
        view.model = model
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onHover = onHover
    }
}

import AppKit
final class HitNSView: NSView {
    var rects: [TreemapRect] = []
    var logicalSize: CGSize = .zero
    var currentSize: CGSize = .zero
    weak var model: AppModel?
    var onClick: ((FileNode, NSEvent.ModifierFlags) -> Void)?
    var onDoubleClick: ((FileNode) -> Void)?
    var onHover: ((FileNode?) -> Void)?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Consume all mouse events in our bounds.
        return bounds.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    private func nodeAt(_ p: NSPoint) -> FileNode? {
        // Convert from the live view's coordinate space into the cached
        // layout's coordinate space (which is where `rects` live). Scale
        // lazily per click so resize frames do zero per-tile work.
        guard logicalSize.width > 0, logicalSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let sx = logicalSize.width / bounds.width
        let sy = logicalSize.height / bounds.height
        let q = NSPoint(x: p.x * sx, y: p.y * sy)
        // Scan in reverse so nested (smaller) rects win over ancestors.
        for tr in rects.reversed() {
            if tr.rect.contains(q) { return tr.node }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let n = nodeAt(p) else { return }
        if event.clickCount >= 2 {
            onDoubleClick?(n)
        } else {
            onClick?(n, event.modifierFlags)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        onHover?(nodeAt(p))
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let node = nodeAt(p), let model = model else { return nil }
        // Match Finder behavior: only switch the selection if the right-clicked
        // tile isn't already in the multi-selection.
        if !model.selectedNodes.contains(where: { $0 === node }) {
            onClick?(node, [])
        }
        return NodeContextMenu.build(for: node, model: model)
    }
}
