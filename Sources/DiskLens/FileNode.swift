import Foundation

// A node in the scanned file tree. Reference type because we mutate during scan
// and hand pointers around to the treemap without copying gigabytes of data.
final class FileNode: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    weak var parent: FileNode?
    var children: [FileNode] = []
    var totalSize: Int64 = 0
    var fileCount: Int = 0
    var dirCount: Int = 0

    init(url: URL, name: String, isDirectory: Bool, parent: FileNode? = nil) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.parent = parent
    }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var ext: String {
        if isDirectory { return "" }
        let e = (name as NSString).pathExtension.lowercased()
        return e.isEmpty ? "<none>" : e
    }

    // Stable depth-first iteration used by the treemap.
    func allFiles() -> [FileNode] {
        var out: [FileNode] = []
        var stack: [FileNode] = [self]
        while let n = stack.popLast() {
            if n.isDirectory {
                stack.append(contentsOf: n.children)
            } else {
                out.append(n)
            }
        }
        return out
    }
}
