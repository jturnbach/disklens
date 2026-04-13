import Foundation

// Generates a compact, human-readable text snapshot of the current scan to
// hand to the AI as the system prompt. We deliberately don't dump the full
// tree (could be hundreds of MB of strings); instead we surface the things a
// cleanup advisor actually needs to reason about: top folders, top files, a
// type breakdown, volume capacity, and the user's current selection.
enum ScanContext {
    @MainActor
    static func systemPrompt(for model: AppModel,
                             topFolders: Int = 30,
                             topFiles: Int = 30) -> String {
        var lines: [String] = []
        lines.append("You are DiskLens Assistant, an expert macOS storage advisor embedded inside the DiskLens disk-usage analyzer app. Your job is to help the user understand what's taking up space on their Mac and recommend what is safe to delete and what they should keep.")
        lines.append("")
        lines.append("Always be specific. Reference exact paths and sizes from the scan report below. Be cautious with anything in /System, /Library, ~/Library/Application Support, ~/Library/Mail, Xcode DerivedData / Caches, and similar — distinguish between safe-to-delete caches and load-bearing files. When in doubt, recommend the user verify before deleting.")
        lines.append("")
        lines.append("=== RESPONSE FORMAT ===")
        lines.append("Write your explanation in concise Markdown prose (bullets, bold, short paragraphs). KEEP THE PROSE SHORT — one or two sentences of intro, then the recommendations.")
        lines.append("")
        lines.append("When you recommend specific files or folders the user can delete, you MUST ALSO emit a single fenced code block tagged `diskclean` containing a JSON array. DiskLens parses this block and renders each entry as an interactive card with Delete/Skip buttons, so the user never has to copy paths manually.")
        lines.append("")
        lines.append("Format of the block:")
        lines.append("```diskclean")
        lines.append("[")
        lines.append("  {")
        lines.append("    \"path\": \"<absolute path exactly as it appears in the scan report>\",")
        lines.append("    \"reason\": \"<one concise sentence explaining why this can be deleted>\",")
        lines.append("    \"confidence\": \"safe\" | \"probably-safe\" | \"verify-first\"")
        lines.append("  }")
        lines.append("]")
        lines.append("```")
        lines.append("")
        lines.append("Rules for the block:")
        lines.append("- Only include paths that literally appear in the TOP FOLDERS or TOP FILES lists below. Do not invent paths.")
        lines.append("- Use absolute paths (starting with /), exactly as shown — including case and any special characters.")
        lines.append("- NEVER suggest paths under these system roots — DiskLens cannot delete them and the user will see permission errors:")
        lines.append("    /System, /private, /usr, /bin, /sbin, /opt, /Library, /Applications (the top-level one — user apps are fine)")
        lines.append("- STRONGLY PREFER paths inside the user's home folder that are owned by the user:")
        lines.append("    ~/Library/Caches, ~/Library/Developer (Xcode derived data, iOS device support, simulator data), ~/Library/Logs, ~/Library/Containers/*/Data/Library/Caches, ~/Downloads (old installers), ~/.Trash")
        lines.append("- NEVER suggest the user's iCloud drive, ~/Documents, ~/Desktop, ~/Movies, ~/Music, ~/Pictures contents unless the user explicitly asked about them — those are irreplaceable personal files.")
        lines.append("- Set confidence=\"safe\" only for caches, logs, derived data, trashes, download archives, and similar truly throwaway content. Use \"verify-first\" for anything that might be user data, project files, or app state.")
        lines.append("- Limit to at most 12 items per response to keep the card stack focused.")
        lines.append("- Emit the block even if you have only one suggestion.")
        lines.append("- If the user is asking a question that does NOT call for deletions (\"what's eating my disk?\"), describe the situation in prose and skip the block.")
        lines.append("")

        guard let root = model.root else {
            lines.append("CURRENT SCAN: none. The user has not run a scan yet. Ask them to scan a folder or disk first.")
            return lines.joined(separator: "\n")
        }

        // ----- Header -----
        lines.append("=== CURRENT SCAN ===")
        lines.append("Scan root: \(root.url.path)")
        if model.scanRootIsVolume, let name = model.volumeName {
            lines.append("Volume: \(name)")
            lines.append("Volume capacity: \(humanBytes(model.volumeTotalBytes))")
            lines.append("Volume free: \(humanBytes(model.volumeFreeBytes))")
            lines.append("Volume used: \(humanBytes(model.volumeTotalBytes - model.volumeFreeBytes))")
        }
        lines.append("Scanned size: \(humanBytes(root.totalSize))")
        lines.append("Files: \(root.fileCount.formatted())")
        lines.append("Folders: \(root.dirCount.formatted())")
        lines.append("")

        // ----- File type breakdown -----
        lines.append("=== FILE TYPE BREAKDOWN ===")
        for (cat, bytes) in model.legend {
            let pct = root.totalSize > 0
                ? Double(bytes) / Double(root.totalSize) * 100
                : 0
            lines.append(String(format: "- %@: %@ (%.1f%%)",
                                cat.displayName, humanBytes(bytes), pct))
        }
        lines.append("")

        // ----- Top folders by size -----
        lines.append("=== TOP \(topFolders) FOLDERS BY SIZE ===")
        let folders = collectTopDirs(root: root, limit: topFolders)
        for (i, n) in folders.enumerated() {
            let pct = root.totalSize > 0
                ? Double(n.totalSize) / Double(root.totalSize) * 100
                : 0
            lines.append(String(format: "%2d. %@ — %@ (%.1f%% of scan, %d files)",
                                i + 1,
                                n.url.path,
                                humanBytes(n.totalSize),
                                pct,
                                n.fileCount))
        }
        lines.append("")

        // ----- Top individual files -----
        lines.append("=== TOP \(topFiles) INDIVIDUAL FILES BY SIZE ===")
        let files = collectTopFiles(root: root, limit: topFiles)
        for (i, n) in files.enumerated() {
            lines.append(String(format: "%2d. %@ — %@",
                                i + 1, n.url.path, humanBytes(n.totalSize)))
        }
        lines.append("")

        // ----- User's current selection (live context) -----
        if !model.selectedNodes.isEmpty {
            lines.append("=== USER'S CURRENT SELECTION ===")
            let canonical = model.canonicalSelection()
            lines.append("Selection count: \(canonical.count) item(s), \(humanBytes(model.selectionTotalSize)) total")
            for n in canonical.prefix(10) {
                lines.append("- \(n.url.path) (\(humanBytes(n.totalSize)))")
            }
            if canonical.count > 10 {
                lines.append("... and \(canonical.count - 10) more")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // Walk the tree once and pick the top N directories by size. We descend
    // into every directory (not just immediate children) so the report
    // surfaces deep heavyweights like Library/Caches/com.apple.* that would
    // otherwise hide.
    private static func collectTopDirs(root: FileNode, limit: Int) -> [FileNode] {
        var all: [FileNode] = []
        var stack: [FileNode] = [root]
        while let n = stack.popLast() {
            if n.isDirectory && n !== root && n.totalSize > 0 {
                all.append(n)
            }
            if n.isDirectory { stack.append(contentsOf: n.children) }
        }
        all.sort { $0.totalSize > $1.totalSize }
        return Array(all.prefix(limit))
    }

    private static func collectTopFiles(root: FileNode, limit: Int) -> [FileNode] {
        var all: [FileNode] = []
        var stack: [FileNode] = [root]
        while let n = stack.popLast() {
            if !n.isDirectory && n.totalSize > 0 {
                all.append(n)
            }
            if n.isDirectory { stack.append(contentsOf: n.children) }
        }
        all.sort { $0.totalSize > $1.totalSize }
        return Array(all.prefix(limit))
    }

    private static func humanBytes(_ bytes: Int64) -> String {
        ByteFormatter.string(bytes)
    }
}
