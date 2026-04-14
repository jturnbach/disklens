import SwiftUI

// Block-level markdown renderer for assistant replies. SwiftUI's
// AttributedString(markdown:) handles inline formatting (bold, italic,
// inline code, links) but not block-level elements — headings, bullet
// lists, code blocks, blockquotes, horizontal rules. This view parses the
// markdown into a block list and renders each block as its own SwiftUI
// view, with inline runs delegated back to AttributedString.
struct MarkdownView: View {
    let markdown: String
    var baseFontSize: CGFloat = 12.5

    var body: some View {
        let blocks = MarkdownParser.parse(markdown)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { i in
                MarkdownBlockView(block: blocks[i],
                                   baseFontSize: baseFontSize)
            }
        }
    }
}

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bulletList([String])
    case numberedList([(Int, String)])
    case codeBlock(language: String?, code: String)
    case blockquote([String])
    case rule

    static func == (lhs: MarkdownBlock, rhs: MarkdownBlock) -> Bool {
        // Only used to satisfy ForEach requirements; identity of content
        // strings is sufficient.
        switch (lhs, rhs) {
        case (.rule, .rule): return true
        case (.heading(let a, let b), .heading(let c, let d)):
            return a == c && b == d
        case (.paragraph(let a), .paragraph(let b)): return a == b
        case (.bulletList(let a), .bulletList(let b)): return a == b
        case (.codeBlock(let al, let ac), .codeBlock(let bl, let bc)):
            return al == bl && ac == bc
        case (.blockquote(let a), .blockquote(let b)): return a == b
        case (.numberedList(let a), .numberedList(let b)):
            guard a.count == b.count else { return false }
            return zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block.
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces)
                        .hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.codeBlock(
                    language: lang.isEmpty ? nil : lang,
                    code: codeLines.joined(separator: "\n")))
                continue
            }

            // Blank line — just a separator between blocks.
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Horizontal rule.
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.rule)
                i += 1
                continue
            }

            // Heading.
            if let heading = parseHeading(trimmed) {
                blocks.append(.heading(level: heading.0, text: heading.1))
                i += 1
                continue
            }

            // Bullet list (collect consecutive items).
            if isBulletItem(trimmed) {
                var items: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if !isBulletItem(t) { break }
                    items.append(stripBulletPrefix(t))
                    i += 1
                }
                blocks.append(.bulletList(items))
                continue
            }

            // Numbered list.
            if let num = parseNumberedItem(trimmed) {
                var items: [(Int, String)] = [num]
                i += 1
                while i < lines.count {
                    if let next = parseNumberedItem(
                        lines[i].trimmingCharacters(in: .whitespaces)) {
                        items.append(next)
                        i += 1
                    } else { break }
                }
                blocks.append(.numberedList(items))
                continue
            }

            // Blockquote.
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("> ") {
                        quoteLines.append(String(t.dropFirst(2)))
                    } else if t == ">" {
                        quoteLines.append("")
                    } else {
                        break
                    }
                    i += 1
                }
                blocks.append(.blockquote(quoteLines))
                continue
            }

            // Paragraph — gather until a blank line or start of a new
            // block-level construct.
            var paraLines: [String] = [line]
            i += 1
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || isBulletItem(t)
                    || parseNumberedItem(t) != nil
                    || t.hasPrefix("#") || t.hasPrefix("```")
                    || t.hasPrefix(">") || t == "---" {
                    break
                }
                paraLines.append(lines[i])
                i += 1
            }
            blocks.append(.paragraph(paraLines.joined(separator: " ")))
        }
        return blocks
    }

    private static func parseHeading(_ line: String) -> (Int, String)? {
        var level = 0
        var s = Substring(line)
        while s.hasPrefix("#") && level < 6 {
            s = s.dropFirst()
            level += 1
        }
        if level > 0 && s.hasPrefix(" ") {
            return (level,
                    String(s.dropFirst()).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func isBulletItem(_ line: String) -> Bool {
        return line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }

    private static func stripBulletPrefix(_ line: String) -> String {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return String(line.dropFirst(2))
        }
        return line
    }

    private static func parseNumberedItem(_ line: String) -> (Int, String)? {
        var idx = line.startIndex
        var digits = ""
        while idx < line.endIndex && line[idx].isNumber {
            digits.append(line[idx])
            idx = line.index(after: idx)
        }
        guard !digits.isEmpty, let num = Int(digits),
              idx < line.endIndex, line[idx] == "." else {
            return nil
        }
        idx = line.index(after: idx)
        guard idx < line.endIndex, line[idx] == " " else { return nil }
        idx = line.index(after: idx)
        return (num, String(line[idx...]))
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let baseFontSize: CGFloat

    var body: some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text)
                .font(.system(size: headingSize(level),
                              weight: level <= 2 ? .bold : .semibold,
                              design: .rounded))
                .padding(.top, level <= 2 ? 4 : 2)

        case .paragraph(let text):
            inlineText(text)
                .font(.system(size: baseFontSize))
                .fixedSize(horizontal: false, vertical: true)

        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(.system(size: baseFontSize, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 10, alignment: .center)
                        inlineText(items[i])
                            .font(.system(size: baseFontSize))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .numberedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(items[i].0).")
                            .font(.system(size: baseFontSize,
                                          weight: .semibold,
                                          design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 18, alignment: .trailing)
                        inlineText(items[i].1)
                            .font(.system(size: baseFontSize))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .codeBlock(let language, let code):
            VStack(alignment: .leading, spacing: 6) {
                if let lang = language {
                    Text(lang.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .tracking(0.5)
                }
                Text(code)
                    .font(.system(size: baseFontSize - 1,
                                  weight: .regular,
                                  design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.black.opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            )

        case .blockquote(let lines):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.purple.opacity(0.55))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(lines.indices, id: \.self) { i in
                        inlineText(lines[i])
                            .font(.system(size: baseFontSize))
                            .italic()
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .rule:
            Rectangle()
                .fill(Color.primary.opacity(0.15))
                .frame(height: 1)
                .padding(.vertical, 4)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return baseFontSize + 5
        case 2: return baseFontSize + 3
        case 3: return baseFontSize + 1.5
        default: return baseFontSize + 0.5
        }
    }

    // Inline formatting handled by AttributedString(markdown:) — bold,
    // italic, `code`, links, strikethrough all resolve automatically.
    private func inlineText(_ text: String) -> Text {
        if let attr = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attr)
        }
        return Text(text)
    }
}
