import SwiftUI
import AppKit

// Single horizontal stacked bar: each segment is one file-type category, with
// an optional "free space" tail when the scan root is a whole volume. Drawn
// in a Canvas so the segments butt up tightly against each other regardless
// of float-rounding (HStack of frame-sized rects accumulates per-pixel error).
struct StackedUsageBar: View {
    struct Segment: Identifiable {
        var id: String { name }
        let name: String
        let color: Color
        let bytes: Int64
    }

    let segments: [Segment]
    let freeBytes: Int64
    let totalCapacity: Int64

    var body: some View {
        Canvas { ctx, size in
            guard totalCapacity > 0 else { return }
            let w = size.width
            let h = size.height
            var x: CGFloat = 0
            for s in segments {
                let frac = Double(s.bytes) / Double(totalCapacity)
                let segW = w * frac
                if segW < 0.5 { continue }
                let rect = CGRect(x: x, y: 0, width: segW, height: h)
                ctx.fill(Path(rect), with: .color(s.color))
                // Subtle vertical highlight for a hint of depth.
                ctx.fill(Path(rect), with: .linearGradient(
                    Gradient(colors: [
                        Color.white.opacity(0.22),
                        Color.clear,
                        Color.black.opacity(0.18)
                    ]),
                    startPoint: CGPoint(x: rect.midX, y: rect.minY),
                    endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
                x += segW
            }
            // Free-space tail.
            if x < w - 0.5 {
                let rect = CGRect(x: x, y: 0, width: w - x, height: h)
                ctx.fill(Path(rect), with: .color(Color.gray.opacity(0.22)))
                ctx.fill(Path(rect), with: .linearGradient(
                    Gradient(colors: [
                        Color.white.opacity(0.10),
                        Color.clear
                    ]),
                    startPoint: CGPoint(x: rect.midX, y: rect.minY),
                    endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
                _ = freeBytes
            }
        }
        .frame(height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5)
        )
    }
}

struct SidePane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                summaryCard
                if model.showPreview, let n = model.primarySelected {
                    previewCard(n)
                }
                selectionCard
            }
            .padding(14)
        }
    }

    // MARK: - Summary card with stacked bar

    private var summaryCard: some View {
        let usedSegments = model.legend.map { (cat, bytes) in
            StackedUsageBar.Segment(
                name: cat.displayName,
                color: cat.color,
                bytes: bytes)
        }
        let scannedBytes = model.root?.totalSize ?? 0
        let total: Int64
        let freeBytes: Int64
        let titleSubtitle: (String, String)

        if model.scanRootIsVolume && model.volumeTotalBytes > 0 {
            total = model.volumeTotalBytes
            freeBytes = model.volumeFreeBytes
            titleSubtitle = (
                model.volumeName ?? model.root?.name ?? "Volume",
                "\(ByteFormatter.string(model.volumeTotalBytes - model.volumeFreeBytes)) used of \(ByteFormatter.string(model.volumeTotalBytes))"
            )
        } else {
            total = scannedBytes
            freeBytes = 0
            titleSubtitle = (
                model.root?.name ?? "No scan",
                "\(ByteFormatter.string(scannedBytes)) scanned"
            )
        }

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(titleSubtitle.0)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(titleSubtitle.1)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if freeBytes > 0 {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Free")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.tertiary)
                        Text(ByteFormatter.string(freeBytes))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            StackedUsageBar(
                segments: usedSegments,
                freeBytes: freeBytes,
                totalCapacity: total)

            // Dot legend, two columns, sorted by size desc.
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), alignment: .leading),
                    GridItem(.flexible(), alignment: .leading),
                ],
                spacing: 6
            ) {
                ForEach(model.legend, id: \.0) { (cat, bytes) in
                    legendDot(cat: cat, bytes: bytes, total: total)
                }
                if freeBytes > 0 {
                    legendDotRaw(
                        color: Color.gray.opacity(0.5),
                        title: "Free",
                        bytes: freeBytes,
                        total: total)
                }
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    @ViewBuilder
    private func legendDot(cat: FileCategory, bytes: Int64, total: Int64) -> some View {
        legendDotRaw(color: cat.color,
                     title: cat.displayName,
                     bytes: bytes,
                     total: total)
    }

    @ViewBuilder
    private func legendDotRaw(color: Color, title: String, bytes: Int64, total: Int64) -> some View {
        let pct = total > 0 ? Double(bytes) / Double(total) * 100 : 0
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .lineLimit(1)
                Text("\(ByteFormatter.string(bytes)) · \(String(format: "%.1f%%", pct))")
                    .font(.system(size: 9, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Selection card

    private var selectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SELECTION")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                Spacer()
                if model.selectedNodes.count > 1 {
                    Text("\(model.selectedNodes.count) items")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                }
            }

            if model.selectedNodes.count > 1 {
                multiSelectionInfo
            } else if let n = model.primarySelected {
                singleSelectionInfo(n)
            } else {
                Text("No selection")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    @ViewBuilder
    private func singleSelectionInfo(_ n: FileNode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: n.url.path))
                    .resizable()
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(n.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(NSString(string: n.url.path).abbreviatingWithTildeInPath)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }

            Divider()

            VStack(spacing: 5) {
                infoRow("Size", value: ByteFormatter.string(n.totalSize))
                if let pct = percentOfRoot(n) {
                    infoRow("Of Total", value: pct)
                }
                if n.isDirectory {
                    infoRow("Files", value: n.fileCount.formatted())
                    infoRow("Folders", value: n.dirCount.formatted())
                } else {
                    let cat = FileTypeClassifier.category(for: n)
                    infoRow("Kind", value: cat.displayName)
                    let extLabel = n.ext == "<none>" ? "—" : ".\(n.ext)"
                    infoRow("Extension", value: extLabel)
                }
                if let date = modificationDate(n.url) {
                    infoRow("Modified", value: date)
                }
                if let date = creationDate(n.url) {
                    infoRow("Created", value: date)
                }
            }
        }
    }

    @ViewBuilder
    private var multiSelectionInfo: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.selectedNodes.count) items selected")
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(ByteFormatter.string(model.selectionTotalSize)) total")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func previewCard(_ n: FileNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PREVIEW")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                Spacer()
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.18))
                if n.isDirectory {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: n.url.path))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(20)
                } else {
                    QuickLookView(url: n.url)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(height: 200)
        }
        .padding(14)
        .background(cardBackground)
    }

    @ViewBuilder
    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
    }

    private func percentOfRoot(_ n: FileNode) -> String? {
        guard let r = model.root, r.totalSize > 0 else { return nil }
        let p = Double(n.totalSize) / Double(r.totalSize) * 100
        return String(format: "%.2f%%", p)
    }

    private func modificationDate(_ url: URL) -> String? {
        guard let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let date = rv.contentModificationDate else { return nil }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    private func creationDate(_ url: URL) -> String? {
        guard let rv = try? url.resourceValues(forKeys: [.creationDateKey]),
              let date = rv.creationDate else { return nil }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
