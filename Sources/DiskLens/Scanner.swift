import Foundation

final class Scanner {
    struct Progress {
        var filesScanned: Int
        var bytesScanned: Int64
        var currentPath: String
    }

    private var cancelled = false
    func cancel() { cancelled = true }

    func scan(root rootURL: URL,
              progress: @escaping (Progress) -> Void,
              completion: @escaping (FileNode?) -> Void) {
        cancelled = false
        DispatchQueue.global(qos: .userInitiated).async {
            let rootName = rootURL.lastPathComponent.isEmpty ? rootURL.path : rootURL.lastPathComponent
            let root = FileNode(url: rootURL, name: rootName, isDirectory: true)
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

    // Iterative directory walker. Skips symlinks to avoid cycles.
    private func walk(node root: FileNode,
                      report: (String, Int64) -> Bool) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileAllocatedSizeKey,
                                       .totalFileAllocatedSizeKey, .isSymbolicLinkKey,
                                       .isPackageKey]
        var stack: [FileNode] = [root]

        while let dir = stack.popLast() {
            if cancelled { return }
            guard let items = try? fm.contentsOfDirectory(
                at: dir.url,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
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
}
