import SwiftUI

struct MarkdownView: View {
    let text: String
    let baseColor: Color

    private enum Block {
        case header(Int, String)
        case codeBlock(String, String?)
        case table([[String]])
        case banner(String, Bool)
        case blockquote(String)
        case list(Bool, AttributedString)
        case paragraph(AttributedString)
    }

    private let blocks: [Block]

    private static var blockCache: [String: [Block]] = [:]
    private static let cacheLock = NSLock()
    private static let maxCacheSize = 200

    init(text: String, baseColor: Color) {
        self.text = text
        self.baseColor = baseColor

        let cacheKey = text
        Self.cacheLock.lock()
        if let cached = Self.blockCache[cacheKey] {
            Self.cacheLock.unlock()
            self.blocks = cached
        } else {
            Self.cacheLock.unlock()
            let parsed = Self.parseBlocks(text, baseColor: baseColor)
            Self.cacheLock.lock()
            if Self.blockCache.count >= Self.maxCacheSize {
                Self.blockCache.removeAll()
            }
            Self.blockCache[cacheKey] = parsed
            Self.cacheLock.unlock()
            self.blocks = parsed
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
    }

    // MARK: - Parsing (runs once per view instance)

    private static func parseBlocks(_ text: String, baseColor: Color) -> [Block] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [Block] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]

            if line.hasPrefix("```") {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                i += 1
                blocks.append(.codeBlock(codeLines.joined(separator: "\n"), lang.isEmpty ? nil : lang))
                continue
            }

            if line.hasPrefix("### ") {
                blocks.append(.header(3, String(line.dropFirst(4))))
                i += 1; continue
            }
            if line.hasPrefix("## ") {
                blocks.append(.header(2, String(line.dropFirst(3))))
                i += 1; continue
            }
            if line.hasPrefix("# ") {
                blocks.append(.header(1, String(line.dropFirst(2))))
                i += 1; continue
            }

            if line.hasPrefix("> ") {
                blocks.append(.blockquote(String(line.dropFirst(2))))
                i += 1; continue
            }

            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let bullet = String(line.dropFirst(2))
                blocks.append(.list(true, inlineAttributedString(bullet, baseColor: baseColor)))
                i += 1; continue
            }

            if line.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
                let content = String(line.drop(while: { $0.isNumber || $0 == "." || $0 == " " }))
                blocks.append(.list(false, inlineAttributedString(content, baseColor: baseColor)))
                i += 1; continue
            }

            if line.hasPrefix("'") && line.hasSuffix("'") && line.count > 2 {
                blocks.append(.banner(String(line.dropFirst().dropLast()), true))
                i += 1; continue
            }

            if line.hasPrefix("\"") && line.hasSuffix("\"") && line.count > 2 {
                blocks.append(.banner(String(line.dropFirst().dropLast()), false))
                i += 1; continue
            }

            if line.contains("|") && i + 1 < lines.count && lines[i + 1].contains("---") {
                var tableRows: [[String]] = []
                while i < lines.count && lines[i].contains("|") {
                    let cells = lines[i].split(separator: "|").map {
                        String($0).trimmingCharacters(in: .whitespaces)
                    }.filter { !$0.isEmpty }
                    if !cells.allSatisfy({ $0.allSatisfy({ $0 == "-" || $0 == ":" }) }) {
                        tableRows.append(cells)
                    }
                    i += 1
                }
                if !tableRows.isEmpty {
                    blocks.append(.table(tableRows))
                }
                continue
            }

            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                blocks.append(.paragraph(inlineAttributedString(line, baseColor: baseColor)))
            }

            i += 1
        }

        return blocks
    }

    /// One AttributedString per paragraph instead of one view per inline fragment.
    private static func inlineAttributedString(_ text: String, baseColor: Color) -> AttributedString {
        var result = AttributedString()
        var remaining = Substring(text)

        let bodyFont = Font.system(size: 11, design: .monospaced)

        func append(_ str: String, font: Font? = nil, color: Color? = nil, background: Color? = nil, link: URL? = nil, underline: Bool = false) {
            guard !str.isEmpty else { return }
            var attr = AttributedString(str)
            attr.font = font ?? bodyFont
            attr.foregroundColor = color ?? baseColor
            if let background { attr.backgroundColor = background }
            if let link { attr.link = link }
            if underline { attr.underlineStyle = .single }
            result += attr
        }

        while !remaining.isEmpty {
            // Find the earliest special marker: **bold**, `code`, or ://link
            var candidates: [(index: String.Index, kind: String)] = []
            if let r = remaining.range(of: "**") { candidates.append((r.lowerBound, "bold")) }
            if let r = remaining.range(of: "`") { candidates.append((r.lowerBound, "code")) }
            if let r = remaining.range(of: "://") { candidates.append((r.lowerBound, "link")) }

            guard let earliest = candidates.min(by: { $0.index < $1.index }) else {
                append(String(remaining))
                break
            }

            append(String(remaining[..<earliest.index]))
            remaining = remaining[earliest.index...]

            switch earliest.kind {
            case "bold":
                remaining = remaining.dropFirst(2)
                if let end = remaining.range(of: "**") {
                    append(String(remaining[..<end.lowerBound]), font: .system(size: 11, weight: .bold, design: .monospaced))
                    remaining = remaining[end.upperBound...]
                } else {
                    append("**")
                }

            case "code":
                remaining = remaining.dropFirst(1)
                if let end = remaining.range(of: "`") {
                    append(String(remaining[..<end.lowerBound]),
                           color: .green,
                           background: Color.green.opacity(0.12))
                    remaining = remaining[end.upperBound...]
                } else {
                    append("`")
                }

            case "link":
                // :// preceded by a letter-only scheme (http, https…)
                let afterSeparator = remaining.index(earliest.index, offsetBy: 3)
                if let protoStart = urlSchemeStart(in: remaining, separatorIndex: earliest.index),
                   let urlEnd = urlEnd(in: remaining, from: afterSeparator) {
                    let urlString = String(remaining[protoStart..<urlEnd])
                    if let url = URL(string: urlString) {
                        append(urlString, color: .blue, link: url, underline: true)
                        remaining = remaining[urlEnd...]
                        continue
                    }
                }
                append("://")
                remaining = remaining[afterSeparator...]

            default:
                break
            }

            // Guard against pathological input where markers never advance.
            if remaining.isEmpty { break }
        }

        return result
    }

    private static func urlSchemeStart(in text: Substring, separatorIndex: String.Index) -> String.Index? {
        var start = separatorIndex
        while start > text.startIndex {
            let before = text.index(before: start)
            guard text[before].isLetter else { return nil }
            start = before
        }
        return start < separatorIndex ? start : nil
    }

    private static func urlEnd(in text: Substring, from index: String.Index) -> String.Index? {
        var end = index
        while end < text.endIndex {
            let ch = text[end]
            if ch.isWhitespace || ch == ">" || ch == ")" || ch == "]" || ch == "\"" { break }
            end = text.index(after: end)
        }
        return end
    }

    // MARK: - Renderer

    @ViewBuilder
    private func renderBlock(_ block: Block) -> some View {
        switch block {
        case .header(let level, let text):
            let fontSize: CGFloat = level == 1 ? 16 : level == 2 ? 14 : 12
            Text(text)
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                .foregroundColor(baseColor)
                .padding(.top, level == 1 ? 4 : 2)

        case .codeBlock(let code, let lang):
            VStack(alignment: .leading, spacing: 2) {
                if let lang {
                    Text(lang)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                }
                Text(code)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.green)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(Color.black.opacity(0.6))
            .cornerRadius(6)
            .padding(.vertical, 2)

        case .table(let rows):
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, cells in
                    HStack(spacing: 0) {
                        ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(rowIdx == 0 ? .white : baseColor)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        }
                    }
                    .background(rowIdx == 0 ? Color.blue.opacity(0.3) : Color.clear)
                }
            }
            .background(Color.white.opacity(0.05))
            .cornerRadius(6)
            .padding(.vertical, 2)

        case .banner(let text, let singleQuote):
            HStack(spacing: 8) {
                Text(singleQuote ? "★" : "◆")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(singleQuote ? .yellow : .cyan)
                Text(text)
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(singleQuote ? .yellow : .cyan)
                    .textSelection(.enabled)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(singleQuote
                        ? Color.yellow.opacity(0.12)
                        : Color.cyan.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(singleQuote
                        ? Color.yellow.opacity(0.3)
                        : Color.cyan.opacity(0.3), lineWidth: 1)
            )
            .padding(.vertical, 2)

        case .blockquote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Color.gray.opacity(0.4))
                    .frame(width: 3)
                Text(text)
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.secondary)
                    .italic()
                    .textSelection(.enabled)
            }
            .padding(.vertical, 2)

        case .list(let bullet, let content):
            HStack(alignment: .top, spacing: 6) {
                Text(bullet ? "•" : "–")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(baseColor.opacity(0.6))
                Text(content)
                    .textSelection(.enabled)
            }

        case .paragraph(let content):
            Text(content)
                .textSelection(.enabled)
        }
    }
}
