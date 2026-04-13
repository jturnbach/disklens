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

// Cushion-shaded treemap renderer. Uses SwiftUI Canvas so drawing of thousands
// of rectangles stays cheap, plus a hit-test index for click routing.
struct TreemapView: View {
    let root: FileNode?
    @Binding var selectedNodes: [FileNode]
    @Binding var zoomRoot: FileNode?
    let mutationToken: Int
    unowned let model: AppModel
    var onDoubleClick: (FileNode) -> Void

    @State private var hovered: FileNode? = nil

    var body: some View {
        GeometryReader { geo in
            let displayRoot = zoomRoot ?? root
            let bounds = CGRect(origin: .zero, size: geo.size)
            let rects: [TreemapRect] = displayRoot.map {
                _ = mutationToken
                return SquarifiedTreemap.layout(root: $0, in: bounds)
            } ?? []

            // Highlight the union of every selected node's subtree (or the
            // node itself if a file). Walking parents per tile would be
            // O(rects×depth); a precomputed set is O(rects) per render.
            let highlightSet: Set<ObjectIdentifier> = {
                let dirs = selectedNodes.filter { $0.isDirectory }
                let files = selectedNodes.filter { !$0.isDirectory }
                if dirs.isEmpty && files.isEmpty { return [] }
                var s = Set<ObjectIdentifier>()
                for f in files { s.insert(ObjectIdentifier(f)) }
                var stack: [FileNode] = dirs
                while let n = stack.popLast() {
                    s.insert(ObjectIdentifier(n))
                    if n.isDirectory { stack.append(contentsOf: n.children) }
                }
                return s
            }()
            // Only dim if the highlight covers a strict subset — i.e. when
            // at least one directory is selected. Pure file selections
            // shouldn't dim everything else, since users still want to see
            // surrounding context when clicking a single tile.
            let dimMode = selectedNodes.contains { $0.isDirectory }

            ZStack {
                Canvas(rendersAsynchronously: false) { ctx, size in
                    // Solid dark backdrop so gaps read as separators.
                    ctx.fill(Path(CGRect(origin: .zero, size: size)),
                             with: .color(Color(red: 0.08, green: 0.08, blue: 0.10)))

                    for tr in rects {
                        let inHighlight = !dimMode
                            || highlightSet.contains(ObjectIdentifier(tr.node))
                        drawCushion(ctx: &ctx, tr: tr, dimmed: !inHighlight)
                    }

                    // Selection outlines. For each selected directory, draw
                    // a single bounding box around its descendant tiles. For
                    // each selected file, draw a per-tile outline.
                    let selectedIds = Set(selectedNodes.map { ObjectIdentifier($0) })
                    for sel in selectedNodes where sel.isDirectory {
                        let descIds = subtreeIds(of: sel)
                        var box: CGRect? = nil
                        for tr in rects where descIds.contains(ObjectIdentifier(tr.node)) {
                            box = box?.union(tr.rect) ?? tr.rect
                        }
                        if let b = box {
                            let path = Path(roundedRect: b.insetBy(dx: 0.5, dy: 0.5),
                                            cornerRadius: 1)
                            ctx.stroke(path, with: .color(.black), lineWidth: 3)
                            ctx.stroke(path, with: .color(.white), lineWidth: 1.5)
                        }
                    }
                    for tr in rects where !tr.node.isDirectory
                        && selectedIds.contains(ObjectIdentifier(tr.node)) {
                        let path = Path(roundedRect: tr.rect.insetBy(dx: 0.5, dy: 0.5),
                                        cornerRadius: 1)
                        ctx.stroke(path, with: .color(.white), lineWidth: 2)
                        ctx.stroke(path, with: .color(.black), lineWidth: 0.5)
                    }
                }
                .drawingGroup()

                // Invisible hit layer: route clicks without re-laying out.
                HitLayer(rects: rects,
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
        }
    }

    private func tooltipText(_ n: FileNode) -> String {
        "\(n.name)  ·  \(ByteFormatter.string(n.totalSize))"
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

    // Cushion shading: base color + linear highlight top-left + shadow
    // bottom-right + thin border. Produces the pillowed look without per-pixel
    // math, which would be ruinous for tens of thousands of rects.
    private func drawCushion(ctx: inout GraphicsContext,
                             tr: TreemapRect,
                             dimmed: Bool = false) {
        let rect = tr.rect
        if rect.width < 1 || rect.height < 1 { return }

        let cat = FileTypeClassifier.category(for: tr.node)
        let base = dimmed
            ? cat.color.opacity(0.18)
            : cat.color
        let path = Path(rect)

        // Base fill.
        ctx.fill(path, with: .color(base))

        // Large-enough tiles get cushion shading; skip for tiny ones.
        if rect.width > 3 && rect.height > 3 {
            let hiAlpha = dimmed ? 0.10 : 0.55
            let hiMidAlpha = dimmed ? 0.02 : 0.08
            let shadowMid = dimmed ? 0.04 : 0.10
            let shadowMax = dimmed ? 0.18 : 0.45

            ctx.fill(path, with: .linearGradient(
                Gradient(colors: [
                    Color.white.opacity(hiAlpha),
                    Color.white.opacity(hiMidAlpha),
                    Color.clear
                ]),
                startPoint: CGPoint(x: rect.minX, y: rect.minY),
                endPoint: CGPoint(x: rect.minX + rect.width * 0.55,
                                  y: rect.minY + rect.height * 0.55)))

            ctx.fill(path, with: .linearGradient(
                Gradient(colors: [
                    Color.clear,
                    Color.black.opacity(shadowMid),
                    Color.black.opacity(shadowMax)
                ]),
                startPoint: CGPoint(x: rect.minX + rect.width * 0.45,
                                    y: rect.minY + rect.height * 0.45),
                endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))

            ctx.stroke(path,
                       with: .color(Color.black.opacity(dimmed ? 0.25 : 0.55)),
                       lineWidth: 0.5)
        }
    }
}

// Transparent NSView that handles mouse events. SwiftUI's onTapGesture is
// per-shape, which would be catastrophic for huge treemaps.
struct HitLayer: NSViewRepresentable {
    let rects: [TreemapRect]
    unowned let model: AppModel
    let onClick: (FileNode, NSEvent.ModifierFlags) -> Void
    let onDoubleClick: (FileNode) -> Void
    let onHover: (FileNode?) -> Void

    func makeNSView(context: Context) -> HitNSView {
        let v = HitNSView()
        v.rects = rects
        v.model = model
        v.onClick = onClick
        v.onDoubleClick = onDoubleClick
        v.onHover = onHover
        return v
    }

    func updateNSView(_ view: HitNSView, context: Context) {
        view.rects = rects
        view.model = model
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onHover = onHover
    }
}

import AppKit
final class HitNSView: NSView {
    var rects: [TreemapRect] = []
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
        // Scan in reverse so nested (smaller) rects win over ancestors.
        for tr in rects.reversed() {
            if tr.rect.contains(p) { return tr.node }
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
