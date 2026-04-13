import Foundation

final class Scanner {
    struct Progress {
        var filesScanned: Int
        var bytesScanned: Int64
        var currentPath: String
    }

    private var cancelled = false
    func cancel() { cancelled = true }

    // MARK: - Full scan

    func scan(root rootURL: URL,
              progress: @escaping (Progress) -> Void,
              completion: @escaping (FileNode?) -> Void) {
        cancelled = false
        DispatchQueue.global(qos: .userInitiated).async {
            let rootName = rootURL.lastPathComponent.isEmpty ? rootURL.path : rootURL.lastPathComponent
            let root = FileNode(url: rootURL, name: rootName, isDirectory: true)
            root.dirMtime = Self.dirModificationDate(rootURL)
            var filesScanned = 0
            var bytesScanned: Int64 = 0
            var lastReport = Date()

            self.walk(node: root) { file, bytes in
                filesScanned += 1
                bytesScanned += bytes
                if Date().timeIntervalSince(lastReport) > 0.1 {
                    lastReport = Date()
                    let p = Progress(filesScanned: filesScanned,
                                     bytesScanned: bytesScanned,
                                     currentPath: file)
                    DispatchQueue.main.async { progress(p) }
                }
                return !self.cancelled
            }

            if self.cancelled {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            self.rollup(root)
            DispatchQueue.main.async { completion(root) }
        }
    }

    // MARK: - Incremental refresh
    //
    // Mutates an existing tree in place. Much cheaper than a full rescan
    // because unchanged directories skip the readdir entirely — we compare
    // each directory's recorded mtime against the current on-disk value
    // and only re-enumerate the ones that changed. Files are always
    // re-stat'd (file size can change without touching the parent dir's
    // mtime), but that's an `lstat(2)` — cheap.

    func refresh(root: FileNode,
                 progress: @escaping (Progress) -> Void,
                 completion: @escaping (Bool) -> Void) {
        cancelled = false
        DispatchQueue.global(qos: .userInitiated).async {
            var counters = RefreshCounters()
            var lastReport = Date()
            let reporter: (String, Int64) -> Void = { file, bytes in
                counters.filesVisited += 1
                counters.bytesSeen += bytes
                if Date().timeIntervalSince(lastReport) > 0.1 {
                    lastReport = Date()
                    let p = Progress(filesScanned: counters.filesVisited,
                                     bytesScanned: counters.bytesSeen,
                                     currentPath: file)
                    DispatchQueue.main.async { progress(p) }
                }
            }
            self.refreshNode(root, report: reporter)
            if self.cancelled {
                DispatchQueue.main.async { completion(false) }
                return
            }
            self.rollup(root)
            DispatchQueue.main.async { completion(true) }
        }
    }

    private struct RefreshCounters {
        var filesVisited: Int = 0
        var bytesSeen: Int64 = 0
    }

    private func refreshNode(_ node: FileNode,
                             report: (String, Int64) -> Void) {
        if cancelled { return }

        // File leaf: single stat, update size in place.
        if !node.isDirectory {
            if let rv = try? node.url.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) {
                let newSize = Int64(rv.totalFileAllocatedSize
                                    ?? rv.fileAllocatedSize
                                    ?? 0)
                node.totalSize = newSize
                report(node.url.path, newSize)
            }
            return
        }

        // Directory: stat its mtime. If the dir doesn't exist anymore we
        // clear its children and drop it — the caller's rollup will purge
        // the size contribution.
        let rv = try? node.url.resourceValues(
            forKeys: [.contentModificationDateKey, .isDirectoryKey])
        guard rv != nil else {
            node.children = []
            node.dirMtime = nil
            return
        }
        let newMtime = rv?.contentModificationDate

        let unchanged: Bool = {
            guard let old = node.dirMtime, let new = newMtime else { return false }
            return abs(old.timeIntervalSinceReferenceDate
                        - new.timeIntervalSinceReferenceDate) < 0.001
        }()

        if unchanged {
            // Immediate children set is identical. Recurse only — no
            // readdir, no allocation. Files inside still get re-stat'd
            // so their size changes are picked up.
            for child in node.children {
                if cancelled { return }
                refreshNode(child, report: report)
            }
        } else {
            // Something was added or removed. Re-enumerate this directory
            // reusing existing children nodes by name where possible, so
            // FileNode references stay valid for anything that didn't move.
            node.dirMtime = newMtime
            reenumerate(dir: node, report: report)
        }
    }

    private func reenumerate(dir: FileNode,
                             report: (String, Int64) -> Void) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey, .isSymbolicLinkKey,
            .contentModificationDateKey
        ]
        guard let items = try? fm.contentsOfDirectory(
            at: dir.url,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            dir.children = []
            return
        }

        var existingByName: [String: FileNode] = [:]
        existingByName.reserveCapacity(dir.children.count)
        for c in dir.children { existingByName[c.name] = c }

        var newChildren: [FileNode] = []
        newChildren.reserveCapacity(items.count)

        for itemURL in items {
            if cancelled { return }
            let rv = try? itemURL.resourceValues(forKeys: Set(keys))
            if rv?.isSymbolicLink == true { continue }
            let isDir = rv?.isDirectory ?? false
            let name = itemURL.lastPathComponent

            if let existing = existingByName[name], existing.isDirectory == isDir {
                // Reuse the existing node — keeps pathIndex and any
                // outstanding FileNode references valid.
                newChildren.append(existing)
                existingByName[name] = nil
                if isDir {
                    existing.dirMtime = rv?.contentModificationDate
                    refreshNode(existing, report: report)
                } else {
                    let size = Int64(rv?.totalFileAllocatedSize
                                      ?? rv?.fileAllocatedSize
                                      ?? 0)
                    existing.totalSize = size
                    report(itemURL.path, size)
                }
            } else {
                // Newly discovered item — full fresh walk for its subtree.
                let node = FileNode(url: itemURL,
                                    name: name,
                                    isDirectory: isDir,
                                    parent: dir)
                if isDir {
                    node.dirMtime = rv?.contentModificationDate
                    walk(node: node) { file, bytes in
                        report(file, bytes)
                        return !self.cancelled
                    }
                } else {
                    let size = Int64(rv?.totalFileAllocatedSize
                                      ?? rv?.fileAllocatedSize
                                      ?? 0)
                    node.totalSize = size
                    report(itemURL.path, size)
                }
                newChildren.append(node)
            }
        }

        // Entries left in existingByName are files/dirs that no longer
        // exist on disk — drop them by not carrying them over.
        dir.children = newChildren
    }

    // MARK: - Full walk

    // Iterative directory walker. Skips symlinks to avoid cycles.
    private func walk(node root: FileNode,
                      report: (String, Int64) -> Bool) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileAllocatedSizeKey,
                                       .totalFileAllocatedSizeKey, .isSymbolicLinkKey,
                                       .isPackageKey, .contentModificationDateKey]
        var stack: [FileNode] = [root]

        while let dir = stack.popLast() {
            if cancelled { return }
            // Intentionally NOT passing .skipsHiddenFiles. A disk usage
            // analyzer must count dot-files and dot-directories: ~/.Trash,
            // ~/.cache, ~/.npm, /.Trashes, /.fseventsd, /.Spotlight-V100,
            // /.DocumentRevisions-V100, /.PKInstallSandboxManager-…, etc.
            // are routinely several GB each and used to silently disappear
            // into the "Unscanned" bucket.
            guard let items = try? fm.contentsOfDirectory(
                at: dir.url,
                includingPropertiesForKeys: keys,
                options: []
            ) else { continue }

            for child in items {
                if cancelled { return }
                let rv = try? child.resourceValues(forKeys: Set(keys))
                let isSym = rv?.isSymbolicLink ?? false
                if isSym { continue }
                let isDir = rv?.isDirectory ?? false

                let node = FileNode(url: child,
                                    name: child.lastPathComponent,
                                    isDirectory: isDir,
                                    parent: dir)
                dir.children.append(node)

                if isDir {
                    node.dirMtime = rv?.contentModificationDate
                    stack.append(node)
                } else {
                    let size = Int64(rv?.totalFileAllocatedSize
                                     ?? rv?.fileAllocatedSize
                                     ?? 0)
                    node.totalSize = size
                    if !report(child.path, size) { return }
                }
            }
        }
    }

    // Post-order sum directory sizes and counts; sort children by size desc.
    private func rollup(_ node: FileNode) {
        if node.isDirectory {
            for c in node.children { rollup(c) }
            node.totalSize = node.children.reduce(0) { $0 + $1.totalSize }
            node.fileCount = node.children.reduce(0) {
                $0 + ($1.isDirectory ? $1.fileCount : 1)
            }
            node.dirCount = node.children.reduce(0) {
                $0 + ($1.isDirectory ? (1 + $1.dirCount) : 0)
            }
            node.children.sort { $0.totalSize > $1.totalSize }
        }
    }

    private static func dirModificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }
}
