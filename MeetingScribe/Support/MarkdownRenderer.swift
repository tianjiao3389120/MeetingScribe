import Foundation

/// Converts the Markdown the model produces into styled HTML for display.
///
/// Deliberately not a general CommonMark implementation — the output shape is
/// constrained by our own system prompt (headings, tables, task lists,
/// blockquotes, emphasis), so handling exactly those keeps this readable and
/// dependency-free. Anything unrecognised falls through as a paragraph rather
/// than being dropped.
enum MarkdownRenderer {

    static func html(from markdown: String, title: String = "会议纪要") -> String {
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
            + "<title>\(escape(title))</title><style>\(stylesheet)</style></head>"
            + "<body><article>\(body(from: markdown))</article></body></html>"
    }

    // MARK: - Block parsing

    static func body(from markdown: String) -> String {
        var out = ""
        let lines = markdown.components(separatedBy: .newlines)
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code
            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                let cls = language.isEmpty ? "" : " class=\"lang-\(escape(language))\""
                out += "<pre><code\(cls)>\(escape(code.joined(separator: "\n")))</code></pre>"
                continue
            }

            if trimmed.isEmpty { index += 1; continue }

            // Horizontal rule
            if trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }), trimmed.count >= 3 {
                out += "<hr>"
                index += 1
                continue
            }

            // Heading
            if let hash = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                let level = trimmed.distance(from: trimmed.startIndex,
                                             to: trimmed.range(of: " ")?.lowerBound ?? trimmed.startIndex)
                let text = String(trimmed[hash.upperBound...])
                out += "<h\(level)>\(inline(text))</h\(level)>"
                index += 1
                continue
            }

            // Table — a header row followed by a separator row of dashes/colons
            if trimmed.contains("|"), index + 1 < lines.count,
               isSeparatorRow(lines[index + 1]) {
                let (table, consumed) = renderTable(lines, from: index)
                out += table
                index += consumed
                continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    var content = String(candidate.dropFirst())
                    if content.hasPrefix(" ") { content.removeFirst() }
                    quoted.append(content)
                    index += 1
                }
                out += "<blockquote>\(body(from: quoted.joined(separator: "\n")))</blockquote>"
                continue
            }

            // Lists (unordered, ordered, task)
            if isListItem(trimmed) {
                let (list, consumed) = renderList(lines, from: index)
                out += list
                index += consumed
                continue
            }

            // Paragraph — gather until a blank line or the start of another block
            var paragraph: [(text: String, hardBreak: Bool)] = []
            while index < lines.count {
                let raw = lines[index]
                let candidate = raw.trimmingCharacters(in: .whitespaces)
                if candidate.isEmpty || isBlockStart(candidate) { break }
                paragraph.append((candidate, raw.hasSuffix("  ") || raw.hasSuffix("\\")))
                index += 1
            }
            if !paragraph.isEmpty {
                let rendered = paragraph.enumerated().map { offset, line in
                    let text = line.hardBreak && line.text.hasSuffix("\\")
                        ? String(line.text.dropLast()) : line.text
                    let separator = offset < paragraph.count - 1
                        ? (line.hardBreak ? "<br>" : " ") : ""
                    return inline(text) + separator
                }.joined()
                out += "<p>\(rendered)</p>"
            }
        }
        return out
    }

    private static func isBlockStart(_ line: String) -> Bool {
        line.hasPrefix("#") || line.hasPrefix(">") || line.hasPrefix("```")
            || isListItem(line)
            || (line.allSatisfy { $0 == "-" || $0 == "*" || $0 == "_" } && line.count >= 3)
    }

    private static func isListItem(_ line: String) -> Bool {
        line.range(of: #"^([-*+]\s+|\d+\.\s+)"#, options: .regularExpression) != nil
    }

    private static func isSeparatorRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") else { return false }
        return trimmed.allSatisfy { "-|: \t".contains($0) }
    }

    // MARK: - Tables

    private static func renderTable(_ lines: [String], from start: Int) -> (String, Int) {
        func cells(_ row: String) -> [String] {
            var text = row.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("|") { text.removeFirst() }
            if text.hasSuffix("|") { text.removeLast() }
            return text.components(separatedBy: "|").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
        }

        let headers = cells(lines[start])
        let alignments = cells(lines[start + 1]).map { spec -> String in
            let left = spec.hasPrefix(":"), right = spec.hasSuffix(":")
            if left && right { return "center" }
            if right { return "right" }
            return "left"
        }

        var html = "<table><thead><tr>"
        for (column, header) in headers.enumerated() {
            let align = column < alignments.count ? alignments[column] : "left"
            html += "<th style=\"text-align:\(align)\">\(inline(header))</th>"
        }
        html += "</tr></thead><tbody>"

        var index = start + 2
        while index < lines.count {
            let row = lines[index].trimmingCharacters(in: .whitespaces)
            guard row.contains("|"), !row.isEmpty else { break }
            html += "<tr>"
            for (column, cell) in cells(row).enumerated() {
                let align = column < alignments.count ? alignments[column] : "left"
                html += "<td style=\"text-align:\(align)\">\(inline(cell))</td>"
            }
            html += "</tr>"
            index += 1
        }
        return (html + "</tbody></table>", index - start)
    }

    // MARK: - Lists

    private static func renderList(_ lines: [String], from start: Int) -> (String, Int) {
        let first = lines[start].trimmingCharacters(in: .whitespaces)
        let ordered = first.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil

        var items: [String] = []
        var index = start
        var hasTaskItem = false

        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }

            if isListItem(trimmed) {
                var content = trimmed.replacingOccurrences(
                    of: #"^([-*+]\s+|\d+\.\s+)"#, with: "", options: .regularExpression)

                // Task list marker
                if let match = content.range(of: #"^\[([ xX])\]\s*"#, options: .regularExpression) {
                    let checked = content[match].contains("x") || content[match].contains("X")
                    content = String(content[match.upperBound...])
                    hasTaskItem = true
                    let box = checked ? "checked" : ""
                    items.append("<label class=\"task\"><input type=\"checkbox\" \(box) disabled>"
                                 + "<span>\(inline(content))</span></label>")
                } else {
                    items.append(inline(content))
                }
                index += 1
            } else if raw.hasPrefix("  ") || raw.hasPrefix("\t") {
                // Continuation of the previous item
                if !items.isEmpty {
                    items[items.count - 1] += " " + inline(trimmed)
                }
                index += 1
            } else {
                break
            }
        }

        let tag = ordered ? "ol" : "ul"
        let cls = hasTaskItem ? " class=\"tasklist\"" : ""
        let html = "<\(tag)\(cls)>" + items.map { "<li>\($0)</li>" }.joined() + "</\(tag)>"
        return (html, index - start)
    }

    // MARK: - Inline

    private static func inline(_ text: String) -> String {
        var out = escape(text)

        // Code spans first so their contents aren't further transformed.
        out = replace(out, #"`([^`]+)`"#, "<code>$1</code>")
        out = replace(out, #"\*\*([^*]+)\*\*"#, "<strong>$1</strong>")
        out = replace(out, #"(?<![*\w])\*([^*\n]+)\*(?![*\w])"#, "<em>$1</em>")
        out = replace(out, #"~~([^~]+)~~"#, "<del>$1</del>")
        out = replace(out, #"\[([^\]]+)\]\(([^)]+)\)"#, "<a href=\"$2\">$1</a>")

        // Bracketed status labels get a pill. The model qualifies them freely
        // ("[进行中 — 待生产更新]"), so allow a phrase, not just a keyword —
        // but require a known status word so ordinary bracketed prose is left
        // alone. Links are already consumed above; `(?!\()` guards the rest.
        out = replace(out,
                      #"\[((?:已闭环|待更新|进行中|等待中|已完成|待确认|待明确|待议)[^\]\[]{0,24})\](?!\()"#,
                      "<span class=\"tag\">$1</span>")

        return out
    }

    private static func replace(_ text: String, _ pattern: String, _ template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - Stylesheet

    /// Follows the system appearance so the pane matches the rest of the app.
    private static let stylesheet = """
    :root {
        color-scheme: light dark;
        --fg: #1d1d1f;
        --muted: #6e6e73;
        --rule: #d2d2d7;
        --bg: #ffffff;
        --surface: #f5f5f7;
        --accent: #0071e3;
    }
    @media (prefers-color-scheme: dark) {
        :root {
            --fg: #f5f5f7;
            --muted: #98989d;
            --rule: #3a3a3c;
            --bg: #1e1e1e;
            --surface: #2c2c2e;
            --accent: #0a84ff;
        }
    }
    * { box-sizing: border-box; }
    body {
        margin: 0;
        background: var(--bg);
        color: var(--fg);
        font: 15px/1.75 -apple-system, "SF Pro Text", "PingFang SC", "Helvetica Neue", sans-serif;
        -webkit-font-smoothing: antialiased;
    }
    article { max-width: 980px; margin: 0 auto; padding: 32px 40px 64px; }
    h1, h2, h3, h4 { line-height: 1.35; font-weight: 600; }
    h1 { font-size: 25px; margin: 0 0 20px; letter-spacing: -0.01em; }
    h2 {
        font-size: 19px;
        margin: 34px 0 14px;
        padding-bottom: 7px;
        border-bottom: 1px solid var(--rule);
    }
    h3 { font-size: 16px; margin: 24px 0 10px; }
    h4 { font-size: 15px; margin: 18px 0 8px; color: var(--muted); }
    p { margin: 10px 0; }
    strong { font-weight: 600; }
    ul, ol { margin: 10px 0; padding-left: 24px; }
    li { margin: 5px 0; }
    h3 + ul > li { margin: 10px 0; }
    li > ul, li > ol { margin: 4px 0; }

    ul.tasklist { list-style: none; padding-left: 2px; }
    ul.tasklist li { margin: 7px 0; }
    .task { display: flex; align-items: flex-start; gap: 9px; }
    .task input {
        margin: 0;
        margin-top: 6px;
        flex: 0 0 auto;
        width: 13px;
        height: 13px;
        accent-color: var(--accent);
    }

    table {
        border-collapse: collapse;
        width: 100%;
        margin: 16px 0;
        font-size: 14px;
        display: block;
        overflow-x: auto;
    }
    th, td {
        border: 1px solid var(--rule);
        padding: 8px 12px;
        vertical-align: top;
    }
    th { background: var(--surface); font-weight: 600; }
    tbody tr:nth-child(even) td { background: color-mix(in srgb, var(--surface) 45%, transparent); }

    blockquote {
        margin: 16px 0;
        padding: 2px 16px;
        border-left: 3px solid var(--rule);
        color: var(--muted);
    }
    blockquote p { margin: 8px 0; }

    code {
        font: 13px/1.5 "SF Mono", ui-monospace, Menlo, monospace;
        background: var(--surface);
        padding: 1.5px 5px;
        border-radius: 4px;
    }
    pre {
        background: var(--surface);
        padding: 13px 16px;
        border-radius: 8px;
        overflow-x: auto;
    }
    pre code { background: none; padding: 0; }

    hr { border: none; border-top: 1px solid var(--rule); margin: 28px 0; }
    a { color: var(--accent); text-decoration: none; }
    a:hover { text-decoration: underline; }

    .tag {
        display: inline-block;
        font-size: 12px;
        line-height: 1.6;
        padding: 0 7px;
        border-radius: 4px;
        background: var(--surface);
        border: 1px solid var(--rule);
        color: var(--muted);
        white-space: nowrap;
    }
    """
}
