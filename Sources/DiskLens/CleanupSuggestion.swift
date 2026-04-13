import Foundation

// One actionable recommendation parsed out of an assistant response.
// Each suggestion starts as .pending and transitions to .deleted, .skipped,
// or .failed as the user acts on it. A suggestion with no resolved node is
// something the AI recommended that we couldn't find in the scan — we still
// show it so the user knows, but actions are disabled.
struct CleanupSuggestion: Identifiable, Equatable {
    enum Confidence: String, Codable {
        case safe
        case probablySafe = "probably-safe"
        case verifyFirst = "verify-first"

        var displayLabel: String {
            switch self {
            case .safe:         return "Safe"
            case .probablySafe: return "Probably Safe"
            case .verifyFirst:  return "Verify First"
            }
        }
    }

    enum Status: Equatable {
        case pending
        case deleted
        case skipped
        case failed(String)
    }

    let id = UUID()
    let path: String
    let reason: String
    let confidence: Confidence
    // Weak-ish reference: resolved from the scan's path index at parse time.
    // We store an ObjectIdentifier as a fingerprint so SwiftUI Equatable
    // comparisons don't bog down on the whole FileNode.
    var nodeRef: NodeRef?
    var status: Status = .pending

    struct NodeRef: Equatable {
        let path: String
        let size: Int64
        let isDirectory: Bool
        let identifier: ObjectIdentifier
    }

    var resolvedSize: Int64 { nodeRef?.size ?? 0 }
    var isResolved: Bool { nodeRef != nil }
}

// Wire-format (what the LLM emits inside the ```diskclean``` fenced block).
// The parser tolerates missing fields and odd casing — the LLM might drift.
private struct SuggestionDTO: Decodable {
    let path: String
    let reason: String?
    let confidence: String?
}

enum SuggestionParser {
    // Strip every ```diskclean JSON block out of the text and return both
    // the cleaned text and the list of suggestions. Assistants are told to
    // emit prose AND the block; we want the prose rendered as-is, so we cut
    // the block from the visible content.
    static func parse(_ text: String,
                      pathIndex: [String: FileNode]) -> (String, [CleanupSuggestion]) {
        // Build a regex that captures a ```diskclean ... ``` block. Swift's
        // NSRegularExpression doesn't do lazy matching tidily; we scan by hand.
        var suggestions: [CleanupSuggestion] = []
        var remaining = text
        var cleaned = ""

        while let range = remaining.range(of: "```diskclean",
                                          options: .caseInsensitive) {
            // Prose before the block.
            cleaned += remaining[..<range.lowerBound]
            let afterTag = remaining[range.upperBound...]
            guard let end = afterTag.range(of: "```") else {
                // No closing fence — treat the rest as prose and stop.
                cleaned += remaining[range.lowerBound...]
                remaining = ""
                break
            }
            let jsonBody = afterTag[..<end.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            suggestions.append(contentsOf: decode(jsonBody, pathIndex: pathIndex))
            remaining = String(afterTag[end.upperBound...])
        }
        cleaned += remaining
        return (
            cleaned.trimmingCharacters(in: .whitespacesAndNewlines),
            suggestions
        )
    }

    private static func decode(_ jsonBody: String,
                                pathIndex: [String: FileNode]) -> [CleanupSuggestion] {
        guard let data = jsonBody.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        // The LLM might emit a single object instead of an array; accept both.
        let dtos: [SuggestionDTO]
        if let arr = try? decoder.decode([SuggestionDTO].self, from: data) {
            dtos = arr
        } else if let single = try? decoder.decode(SuggestionDTO.self, from: data) {
            dtos = [single]
        } else {
            return []
        }
        return dtos.map { dto in
            let conf: CleanupSuggestion.Confidence = {
                switch (dto.confidence ?? "").lowercased() {
                case "safe":                       return .safe
                case "probably-safe", "probably":  return .probablySafe
                default:                           return .verifyFirst
                }
            }()
            let node = pathIndex[dto.path]
                ?? pathIndex[normalize(dto.path)]
            let ref = node.map {
                CleanupSuggestion.NodeRef(
                    path: $0.url.path,
                    size: $0.totalSize,
                    isDirectory: $0.isDirectory,
                    identifier: ObjectIdentifier($0))
            }
            return CleanupSuggestion(
                path: dto.path,
                reason: dto.reason ?? "",
                confidence: conf,
                nodeRef: ref)
        }
    }

    // Small normalization: expand leading ~ and strip trailing slashes so
    // the AI can hand us `~/Downloads/foo` or `/Users/x/Downloads/foo/`.
    private static func normalize(_ path: String) -> String {
        var p = path
        if p.hasPrefix("~/") {
            p = NSString(string: p).expandingTildeInPath
        }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
