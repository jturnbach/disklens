import Foundation
import AppKit
import SwiftUI

// Renders the squarified treemap into a CGImage once, off the SwiftUI
// render path. A CALayer with contentsGravity = .resize then stretches the
// cached image natively during live window resize — no Canvas re-invocation,
// no .drawingGroup() rasterization, no per-frame rect allocations.
@MainActor
final class TreemapRenderer: ObservableObject {
    // The rendered bitmap. Published so TreemapLayerView sees updates.
    @Published private(set) var image: CGImage? = nil

    // Logical rects in the cached layout's coordinate space. The hit layer
    // reads these directly and scales click coordinates lazily.
    private(set) var cachedRects: [TreemapRect] = []
    private(set) var cachedLayoutSize: CGSize = .zero

    private var cachedRootId: ObjectIdentifier? = nil
    private var cachedMutationToken: Int = -1
    private var debounceTask: Task<Void, Never>? = nil

    func requestLayout(root: FileNode?,
                       size: CGSize,
                       mutationToken: Int,
                       immediate: Bool) {
        let rootId = root.map { ObjectIdentifier($0) }
        let tokenChanged = cachedMutationToken != mutationToken
        let rootChanged = cachedRootId != rootId
        let sizeChanged = cachedLayoutSize != size
        let everRendered = image != nil && cachedLayoutSize != .zero

        // Nothing to do if nothing actually changed.
        if !tokenChanged && !rootChanged && !sizeChanged && everRendered {
            return
        }

        debounceTask?.cancel()

        // First render, root change, or tree mutation: go synchronously so
        // the user never sees an empty canvas.
        if !everRendered || rootChanged || tokenChanged || immediate {
            performLayoutAndRender(root: root,
                                   size: size,
                                   mutationToken: mutationToken)
            return
        }

        // Size-only changes (live window resize): debounce 1 s so we skip
        // the expensive layout+render entirely until the user stops
        // dragging. The CALayer keeps stretching the old image in the
        // meantime, which is cheap.
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
            self?.performLayoutAndRender(root: root,
                                         size: size,
                                         mutationToken: mutationToken)
        }
    }

    private func performLayoutAndRender(root: FileNode?,
                                        size: CGSize,
                                        mutationToken: Int) {
        guard size.width > 1, size.height > 1 else { return }
        guard let root = root else {
            cachedRects = []
            cachedLayoutSize = size
            cachedRootId = nil
            cachedMutationToken = mutationToken
            image = nil
            return
        }
        let bounds = CGRect(origin: .zero, size: size)
        let rects = SquarifiedTreemap.layout(root: root, in: bounds)
        cachedRects = rects
        cachedLayoutSize = size
        cachedRootId = ObjectIdentifier(root)
        cachedMutationToken = mutationToken

        // Extract Sendable inputs before dropping the FileNode references
        // and go off-main. 3 k gradient fills cost ~30-80 ms; doing it off
        // the UI thread keeps clicks snappy.
        let renderables: [Renderable] = rects.map {
            Renderable(rect: $0.rect,
                       color: FileTypeClassifier.category(for: $0.node).nsColor)
        }
        let renderSize = size
        let token = mutationToken
        Task.detached(priority: .userInitiated) { [weak self] in
            let cgImage = Self.render(renderables: renderables, size: renderSize)
            await self?.applyRenderedImage(cgImage,
                                            token: token,
                                            size: renderSize)
        }
    }

    private func applyRenderedImage(_ cgImage: CGImage?,
                                     token: Int,
                                     size: CGSize) {
        guard cachedMutationToken == token, cachedLayoutSize == size else {
            return
        }
        image = cgImage
    }

    // MARK: - Rendering

    private struct Renderable: @unchecked Sendable {
        let rect: CGRect
        let color: NSColor
    }

    nonisolated private static func render(renderables: [Renderable],
                                             size: CGSize) -> CGImage? {
        let pxW = max(1, Int(size.width.rounded()))
        let pxH = max(1, Int(size.height.rounded()))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pxW,
            height: pxH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // CG is bottom-left origin; flip so our rects (top-left origin)
        // draw upright.
        ctx.translateBy(x: 0, y: CGFloat(pxH))
        ctx.scaleBy(x: 1, y: -1)

        // Dark backdrop so tiny gaps read as separators.
        ctx.setFillColor(NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))

        for r in renderables {
            drawCushion(ctx: ctx, rect: r.rect, color: r.color)
        }

        return ctx.makeImage()
    }

    nonisolated private static func drawCushion(ctx: CGContext,
                                                  rect: CGRect,
                                                  color: NSColor) {
        if rect.width < 1 || rect.height < 1 { return }
        ctx.setFillColor(color.cgColor)
        ctx.fill(rect)

        // Skip cushion shading on sub-pixel tiles — invisible anyway.
        guard rect.width > 3 && rect.height > 3 else { return }

        let space = CGColorSpaceCreateDeviceRGB()

        // Top-left highlight.
        let highlightColors = [
            NSColor(white: 1, alpha: 0.55).cgColor,
            NSColor(white: 1, alpha: 0.08).cgColor,
            NSColor(white: 1, alpha: 0.0).cgColor
        ] as CFArray
        if let grad = CGGradient(colorsSpace: space,
                                 colors: highlightColors,
                                 locations: [0, 0.5, 1]) {
            ctx.saveGState()
            ctx.addRect(rect)
            ctx.clip()
            ctx.drawLinearGradient(
                grad,
                start: CGPoint(x: rect.minX, y: rect.minY),
                end: CGPoint(x: rect.minX + rect.width * 0.55,
                             y: rect.minY + rect.height * 0.55),
                options: [])
            ctx.restoreGState()
        }

        // Bottom-right shadow.
        let shadowColors = [
            NSColor(white: 0, alpha: 0.0).cgColor,
            NSColor(white: 0, alpha: 0.10).cgColor,
            NSColor(white: 0, alpha: 0.45).cgColor
        ] as CFArray
        if let grad = CGGradient(colorsSpace: space,
                                 colors: shadowColors,
                                 locations: [0, 0.5, 1]) {
            ctx.saveGState()
            ctx.addRect(rect)
            ctx.clip()
            ctx.drawLinearGradient(
                grad,
                start: CGPoint(x: rect.minX + rect.width * 0.45,
                               y: rect.minY + rect.height * 0.45),
                end: CGPoint(x: rect.maxX, y: rect.maxY),
                options: [])
            ctx.restoreGState()
        }

        // Border.
        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.55).cgColor)
        ctx.setLineWidth(0.5)
        ctx.stroke(rect)
    }
}

// NSView wrapper backed by a plain CALayer. Setting layer.contents to a
// CGImage + contentsGravity = .resize makes macOS stretch the cached pixels
// on the GPU as the view resizes — no drawRect, no SwiftUI invocation. This
// is the single fastest way to display a scalable bitmap on macOS.
struct TreemapLayerView: NSViewRepresentable {
    let image: CGImage?

    func makeNSView(context: Context) -> TreemapNSLayerView {
        let v = TreemapNSLayerView()
        v.wantsLayer = true
        v.layerContentsRedrawPolicy = .never
        v.setupLayer()
        return v
    }

    func updateNSView(_ view: TreemapNSLayerView, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.contents = image
        CATransaction.commit()
    }
}

final class TreemapNSLayerView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override var isFlipped: Bool { true }

    func setupLayer() {
        layer = CALayer()
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .linear
        layer?.backgroundColor = NSColor(red: 0.08,
                                          green: 0.08,
                                          blue: 0.10,
                                          alpha: 1).cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
