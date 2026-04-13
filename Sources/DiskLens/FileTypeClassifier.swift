import Foundation
import SwiftUI

// Maps file extensions to stable, human-recognizable colors used in both the
// treemap and the legend panel. Colors are chosen to be bright and distinct on
// both light and dark backgrounds — the cushion shader will darken them.
enum FileCategory: String, CaseIterable, Hashable {
    case video, audio, image, document, code, archive, app, data, system, other

    var displayName: String {
        switch self {
        case .video: return "Video"
        case .audio: return "Audio"
        case .image: return "Image"
        case .document: return "Document"
        case .code: return "Code"
        case .archive: return "Archive"
        case .app: return "Application"
        case .data: return "Data"
        case .system: return "System"
        case .other: return "Other"
        }
    }

    var color: Color {
        switch self {
        case .video:    return Color(red: 0.95, green: 0.30, blue: 0.45)
        case .audio:    return Color(red: 0.90, green: 0.55, blue: 0.20)
        case .image:    return Color(red: 0.95, green: 0.80, blue: 0.20)
        case .document: return Color(red: 0.35, green: 0.75, blue: 0.95)
        case .code:     return Color(red: 0.40, green: 0.85, blue: 0.50)
        case .archive:  return Color(red: 0.65, green: 0.40, blue: 0.85)
        case .app:      return Color(red: 0.30, green: 0.55, blue: 0.95)
        case .data:     return Color(red: 0.20, green: 0.80, blue: 0.75)
        case .system:   return Color(red: 0.60, green: 0.60, blue: 0.65)
        case .other:    return Color(red: 0.75, green: 0.50, blue: 0.55)
        }
    }
}

enum FileTypeClassifier {
    static let map: [String: FileCategory] = [
        // Video
        "mov": .video, "mp4": .video, "m4v": .video, "avi": .video, "mkv": .video,
        "wmv": .video, "flv": .video, "webm": .video, "mpg": .video, "mpeg": .video,
        "vob": .video,
        // Audio
        "mp3": .audio, "m4a": .audio, "aac": .audio, "wav": .audio, "flac": .audio,
        "ogg": .audio, "aiff": .audio, "aif": .audio, "alac": .audio, "opus": .audio,
        // Image
        "jpg": .image, "jpeg": .image, "png": .image, "gif": .image, "bmp": .image,
        "tif": .image, "tiff": .image, "heic": .image, "webp": .image, "svg": .image,
        "raw": .image, "psd": .image, "ai": .image, "icns": .image, "ico": .image,
        // Document
        "pdf": .document, "doc": .document, "docx": .document, "odt": .document,
        "rtf": .document, "txt": .document, "md": .document, "pages": .document,
        "xls": .document, "xlsx": .document, "numbers": .document, "csv": .document,
        "ppt": .document, "pptx": .document, "keynote": .document, "key": .document,
        "epub": .document, "mobi": .document,
        // Code
        "swift": .code, "m": .code, "mm": .code, "h": .code, "c": .code, "cpp": .code,
        "cc": .code, "hpp": .code, "java": .code, "kt": .code, "py": .code, "rb": .code,
        "go": .code, "rs": .code, "js": .code, "ts": .code, "jsx": .code, "tsx": .code,
        "html": .code, "css": .code, "scss": .code, "sh": .code, "zsh": .code,
        "json": .code, "xml": .code, "yaml": .code, "yml": .code, "toml": .code,
        // Archive
        "zip": .archive, "tar": .archive, "gz": .archive, "bz2": .archive, "xz": .archive,
        "7z": .archive, "rar": .archive, "dmg": .archive, "iso": .archive, "pkg": .archive,
        // App
        "app": .app, "framework": .app, "bundle": .app, "kext": .app, "plugin": .app,
        "xpc": .app, "exe": .app, "msi": .app,
        // Data
        "db": .data, "sqlite": .data, "sqlite3": .data, "sql": .data, "parquet": .data,
        "avro": .data, "pbxproj": .data, "plist": .data, "log": .data,
        // System
        "dylib": .system, "so": .system, "a": .system, "o": .system, "cache": .system,
        "tmp": .system,
    ]

    static func category(for node: FileNode) -> FileCategory {
        if node.isDirectory { return .other }
        let ext = (node.name as NSString).pathExtension.lowercased()
        if ext.isEmpty { return .other }
        return map[ext] ?? .other
    }
}
