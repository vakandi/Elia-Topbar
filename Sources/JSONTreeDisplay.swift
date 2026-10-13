import SwiftUI
import AppKit

// MARK: - Syntax-highlighted JSON pretty-printer

private struct HLRun { let text: String; let color: Color; let nsColor: NSColor }
private enum HLKind { case key, string, number, bool, null, punct }

private func hlColor(_ kind: HLKind) -> (Color, NSColor) {
    switch kind {
    case .key: return (.blue, .systemBlue)
    case .string: return (.green, .systemGreen)
    case .number: return (.orange, .systemOrange)
    case .bool: return (.purple, .systemPurple)
    case .null: return (.gray, .systemGray)
    case .punct: return (.secondary, .secondaryLabelColor)
    }
}

private func run(_ text: String, _ kind: HLKind) -> HLRun {
    let (c, n) = hlColor(kind)
    return HLRun(text: text, color: c, nsColor: n)
}

private let maxScalarChars = 600

private func displayString(_ s: String) -> String {
    guard s.count > maxScalarChars else { return s }
    return String(s.prefix(maxScalarChars)) + "… (\(s.count) chars)"
}

private func jsonQuoted(_ s: String) -> String {
    if let d = try? JSONSerialization.data(withJSONObject: [s]),
       var str = String(data: d, encoding: .utf8), str.count >= 2 {
        str.removeFirst(); str.removeLast(); return str
    }
    let e = s.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
    return "\"\(e)\""
}

private func indent(_ level: Int) -> String { String(repeating: " ", count: level * 2) }

private func appendRuns(for value: Any, indent indentLevel: Int, into runs: inout [HLRun]) {
    if let dict = value as? [String: Any] {
        guard !dict.isEmpty else { runs.append(run("{}", .punct)); return }
        runs.append(run("{\n", .punct))
        let keys = Array(dict.keys)
        for (i, key) in keys.enumerated() {
            runs.append(run(indent(indentLevel + 1), .punct))
            runs.append(run(jsonQuoted(key), .key))
            runs.append(run(": ", .punct))
            appendRuns(for: dict[key] as Any, indent: indentLevel + 1, into: &runs)
            runs.append(run(i < keys.count - 1 ? ",\n" : "\n", .punct))
        }
        runs.append(run(indent(indentLevel) + "}", .punct))
    } else if let arr = value as? [Any] {
        guard !arr.isEmpty else { runs.append(run("[]", .punct)); return }
        runs.append(run("[\n", .punct))
        for (i, el) in arr.enumerated() {
            runs.append(run(indent(indentLevel + 1), .punct))
            appendRuns(for: el, indent: indentLevel + 1, into: &runs)
            runs.append(run(i < arr.count - 1 ? ",\n" : "\n", .punct))
        }
        runs.append(run(indent(indentLevel) + "]", .punct))
    } else if value is Bool {
        runs.append(run((value as? Bool) == true ? "true" : "false", .bool))
    } else if let num = value as? NSNumber {
        runs.append(run("\(num)", .number))
    } else if let s = value as? String {
        runs.append(run(jsonQuoted(displayString(s)), .string))
    } else if value is NSNull {
        runs.append(run("null", .null))
    } else {
        let raw = displayString("\(value)")
        runs.append(run("\"" + raw + "\"", .string))
    }
}

private func highlightRuns(_ text: String) -> [HLRun]? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let data = trimmed.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else { return nil }
    var runs: [HLRun] = []
    appendRuns(for: obj, indent: 0, into: &runs)
    return runs
}

func prettyPrintJSON(_ text: String) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    guard let runs = highlightRuns(text) else {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        result.append(NSAttributedString(
            string: t.isEmpty ? "—" : t,
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        ))
        return result
    }
    for r in runs {
        result.append(NSAttributedString(
            string: r.text,
            attributes: [.font: font, .foregroundColor: r.nsColor]
        ))
    }
    return result
}

private func truncatedRuns(_ runs: [HLRun], limit: Int) -> (runs: [HLRun], wasTruncated: Bool) {
    var out: [HLRun] = []
    var count = 0
    for r in runs {
        if count >= limit { return (out, true) }
        let remaining = limit - count
        if r.text.count <= remaining {
            out.append(r); count += r.text.count
        } else {
            out.append(HLRun(text: String(r.text.prefix(remaining)) + "…", color: r.color, nsColor: r.nsColor))
            return (out, true)
        }
    }
    return (out, false)
}

private func runsText(_ runs: [HLRun]) -> Text {
    runs.reduce(Text("")) { acc, r in acc + Text(r.text).foregroundColor(r.color) }
}

// MARK: - JSON Tree View (tap-to-expand)

struct JSONTreeView: View {
    let text: String?
    let maxCharacters: Int
    @State private var expanded = false

    init(text: String?, maxCharacters: Int = 500) {
        self.text = text
        self.maxCharacters = maxCharacters
    }

    var body: some View {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if expanded {
                expandedView(text).onTapGesture { expanded = false }
            } else {
                summaryView(text).onTapGesture { expanded = true }
            }
        } else {
            Text("—")
                .foregroundColor(.secondary)
                .font(.system(size: 10, design: .monospaced))
        }
    }

    private func summaryView(_ text: String) -> some View {
        let summary: String
        if let runs = highlightRuns(text) {
            let single = runs.map { $0.text }.joined()
            let collapsed = single.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            summary = String(collapsed.prefix(160)) + (collapsed.count > 160 ? " …" : "")
        } else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let collapsed = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            summary = String(collapsed.prefix(160)) + (collapsed.count > 160 ? " …" : "")
        }
        return HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
            Text(summary)
                .foregroundColor(.primary.opacity(0.85))
                .lineLimit(3)
                .truncationMode(.tail)
        }
        .font(.system(size: 10, design: .monospaced))
        .textSelection(.enabled)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.18), lineWidth: 1))
    }

    private func expandedView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("tap to collapse")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 4)
            HStack(alignment: .top, spacing: 0) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: 2)
                    .padding(.leading, 10)
                    .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 2) {
                    if let runs = highlightRuns(text) {
                        let (shown, wasTruncated) = truncatedRuns(runs, limit: maxCharacters)
                        runsText(shown)
                            .font(.system(size: 10, design: .monospaced))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                        if wasTruncated {
                            Text("… (\(runs.map { $0.text }.joined().count) chars total)")
                                .foregroundColor(.secondary)
                                .font(.system(size: 9, design: .monospaced))
                        }
                    } else {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        Text(trimmed.count > maxCharacters ? String(trimmed.prefix(maxCharacters)) + "…" : trimmed)
                            .font(.system(size: 10, design: .monospaced))
                            .lineSpacing(2)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, 8)
                .padding(.vertical, 4)
                Spacer(minLength: 0)
            }
        }
        .padding(.bottom, 6)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.18), lineWidth: 1))
    }
}

// MARK: - JSON Tree Display

struct JSONTreeDisplay: View {
    let text: String?
    let maxCharacters: Int

    init(text: String?, maxCharacters: Int = 500) {
        self.text = text
        self.maxCharacters = maxCharacters
    }

    var body: some View {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            JSONTreeView(text: text, maxCharacters: maxCharacters)
        } else {
            Text("—")
                .foregroundColor(.secondary)
                .font(.system(size: 10, design: .monospaced))
        }
    }
}

// MARK: - Tool JSON Display

struct ToolJSONDisplay: View {
    let name: String
    let input: String?
    let output: String?

    init(name: String, input: String?, output: String?) {
        self.name = name
        self.input = input
        self.output = output
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Tool banner
            HStack(spacing: 6) {
                Image(systemName: LivestreamParsing.toolIcon(name))
                    .foregroundColor(LivestreamParsing.toolColor(name))
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 16)
                Text(LivestreamParsing.toolDisplayName(name))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(LivestreamParsing.toolColor(name))
                // File path for read/write/edit/grep/glob — also handles 'pattern' for glob
                if let filePath = extractFilePath(name: name, input: input) {
                    Text(filePath)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(LivestreamParsing.toolColor(name).opacity(0.08))
            .cornerRadius(6)

            // Formatted content directly from LivestreamParsing — no Input/Output labels
            if let input, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let formatted = LivestreamParsing.formatToolInput(name: name, raw: input)
                if !formatted.isEmpty {
                    Text(formatted)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
                        .cornerRadius(3)
                } else {
                    JSONTreeDisplay(text: input, maxCharacters: 500).padding(4)
                }
            }

            if let output, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(output)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
                    .cornerRadius(3)
            }

            if input == nil && output == nil {
                Text("—")
                    .foregroundColor(.secondary)
                    .font(.system(size: 9, design: .monospaced))
                    .padding(.leading, 2)
            }
        }
        .padding(6)
    }

    private func extractFilePath(name: String, input: String?) -> String? {
        guard let input, !input.isEmpty,
              let data = input.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        func deep(_ v: Any, depth: Int = 0) -> String? {
            guard depth < 4 else { return nil }
            if let o = v as? [String: Any] {
                for k in ["filePath", "file_path", "path", "filepath", "pattern", "file", "filename", "target", "dir", "directory", "cwd"] {
                    if let s = o[k] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
                }
                for (_, vv) in o { if let s = deep(vv, depth: depth + 1) { return s } }
            }
            if let a = v as? [Any] { for vv in a { if let s = deep(vv, depth: depth + 1) { return s } } }
            return nil
        }
        guard let path = deep(obj), !path.isEmpty else { return nil }
        return LivestreamParsing.hostPath(path)
    }
}
