import Foundation
import SwiftUI

// MARK: - 轻量 Markdown 渲染（零依赖）

/// 把模型返回的 Markdown 渲染成原生 SwiftUI，不做网络请求、不引入三方库。
///
/// 块级：标题、无序列表、有序列表、引用、代码块、分割线、段落、表格
/// 行内：粗体、斜体、行内代码、链接（交给 AttributedString 处理）
struct MarkdownText: View {
    let raw: String

    init(_ raw: String) { self.raw = raw }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(MarkdownBlock.parse(raw).enumerated()), id: \.offset) { _, block in
                block.view
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 行内 Markdown：粗体 / 斜体 / 行内代码 / 链接
struct MarkdownInline: View {
    private let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(attributed)
    }

    private var attributed: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let parsed = try? AttributedString(markdown: text, options: options) {
            return parsed
        }
        return AttributedString(text)
    }
}

// MARK: - 块级解析

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet([String])
    case ordered([String])
    case quote(String)
    case code(String)
    case divider
    /// | 表头 | … |   +   |---|---|
    case table(headers: [String], rows: [[String]], aligns: [Alignment])

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var orderedItems: [String] = []
        var quote: [String] = []
        var codeLines: [String] = []
        var inCode = false

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            }
            if !bullets.isEmpty { blocks.append(.bullet(bullets)); bullets.removeAll() }
            if !orderedItems.isEmpty { blocks.append(.ordered(orderedItems)); orderedItems.removeAll() }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote.removeAll() }
        }

        let lines = text.components(separatedBy: .newlines)
        var i = 0

        // 用下标遍历（而不是 for-in）：表格需要看下一行才知道是不是表格
        while i < lines.count {
            let rawLine = lines[i]
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            i += 1

            // 代码块围栏
            if line.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                    inCode = false
                } else {
                    flush()
                    inCode = true
                }
                continue
            }
            if inCode {
                codeLines.append(rawLine)
                continue
            }

            if line.isEmpty { flush(); continue }

            if line == "---" || line == "***" || line == "___" {
                flush()
                blocks.append(.divider)
                continue
            }

            // 表格：本行是 | a | b |，且下一行是 |---|---| 分隔行
            if isTableRow(line), i < lines.count, isTableSeparator(lines[i]) {
                flush()
                let headers = splitTableRow(line)
                let aligns = tableAlignments(lines[i], count: headers.count)
                i += 1   // 跳过分隔行
                var rows: [[String]] = []
                while i < lines.count {
                    let next = lines[i].trimmingCharacters(in: .whitespaces)
                    guard isTableRow(next) else { break }
                    rows.append(splitTableRow(next))
                    i += 1
                }
                blocks.append(.table(headers: headers, rows: rows, aligns: aligns))
                continue
            }

            if let (level, content) = heading(line) {
                flush()
                blocks.append(.heading(level: level, text: content))
                continue
            }

            if let item = stripping(line, prefixes: ["- ", "* ", "+ ", "• "]) {
                flush()
                bullets.append(item)
                continue
            }

            if let item = orderedItem(line) {
                flush()
                orderedItems.append(item)
                continue
            }

            if line.hasPrefix(">") {
                flush()
                let body = line.hasPrefix("> ") ? String(line.dropFirst(2)) : String(line.dropFirst())
                quote.append(body.trimmingCharacters(in: .whitespaces))
                continue
            }

            if !bullets.isEmpty || !orderedItems.isEmpty || !quote.isEmpty { flush() }
            paragraph.append(line)
        }

        if inCode, !codeLines.isEmpty { blocks.append(.code(codeLines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    // MARK: 辅助

    private static func heading(_ line: String) -> (Int, String)? {
        var count = 0
        for ch in line {
            if ch == "#" { count += 1 } else { break }
        }
        guard (1...6).contains(count) else { return nil }
        let rest = line.dropFirst(count)
        guard rest.hasPrefix(" ") else { return nil }
        return (count, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func stripping(_ line: String, prefixes: [String]) -> String? {
        for p in prefixes where line.hasPrefix(p) {
            return String(line.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// 匹配 "1. 内容" / "12) 内容"
    private static func orderedItem(_ line: String) -> String? {
        var idx = line.startIndex
        while idx < line.endIndex, line[idx].isNumber {
            idx = line.index(after: idx)
        }
        guard idx > line.startIndex, idx < line.endIndex else { return nil }
        guard line[idx] == "." || line[idx] == ")" else { return nil }
        let after = line.index(after: idx)
        guard after < line.endIndex, line[after] == " " else { return nil }
        return String(line[line.index(after: after)...]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: 表格辅助

    /// 表格行：以 | 开头且至少有 3 个 |（即至少一格内容）。
    /// 只认带前导竖线的写法，避免把正文里的「A | B」误判成表格。
    private static func isTableRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|") else { return false }
        return t.filter { $0 == "|" }.count >= 2
    }

    /// 分隔行：|---|---|、| :--- | ---: | 之类
    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-") else { return false }
        let body = t.replacingOccurrences(of: "|", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return false }
        return body.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
    }

    private static func splitTableRow(_ line: String) -> [String] {
        // 先把转义的 \| 藏起来，免得被当成分隔符
        let placeholder = "\u{0001}"
        var t = line.replacingOccurrences(of: "\\|", with: placeholder)
        t = t.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map {
            $0.replacingOccurrences(of: placeholder, with: "|")
                .trimmingCharacters(in: .whitespaces)
        }
    }

    /// 从分隔行的冒号推断每列对齐方式
    private static func tableAlignments(_ line: String, count: Int) -> [Alignment] {
        let cells = splitTableRow(line)
        return (0..<count).map { i in
            let c = i < cells.count ? cells[i] : ""
            let left = c.hasPrefix(":")
            let right = c.hasSuffix(":")
            if left && right { return .center }
            if right { return .trailing }
            return .leading
        }
    }
}

// MARK: - 块级渲染

extension MarkdownBlock {
    @ViewBuilder
    var view: some View {
        switch self {
        case .heading(let level, let text):
            MarkdownInline(text)
                .font(.system(size: level <= 1 ? 17 : (level == 2 ? 16 : 15), weight: .semibold))
                .padding(.top, 2)

        case .paragraph(let text):
            MarkdownInline(text)

        case .bullet(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 7) {
                        Text("•").foregroundColor(.secondary)
                        MarkdownInline(item)
                    }
                }
            }

        case .ordered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 7) {
                        Text("\(index + 1).")
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                        MarkdownInline(item)
                    }
                }
            }

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 3)
                MarkdownInline(text)
                    .foregroundColor(.secondary)
            }

        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

        case .divider:
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .frame(height: 1)
                .padding(.vertical, 2)

        case .table(let headers, let rows, let aligns):
            table(headers: headers, rows: rows, aligns: aligns)
        }
    }

    // MARK: 表格渲染

    /// 等宽列的简易表格：列宽平分气泡宽度，长文本自动换行，不需要横向滚动
    private func table(headers: [String], rows: [[String]], aligns: [Alignment]) -> some View {
        let columns = max(1, headers.count)
        return VStack(spacing: 0) {
            tableRow(headers, columns: columns, aligns: aligns, isHeader: true)
            ForEach(rows.indices, id: \.self) { r in
                Divider().overlay(Color.secondary.opacity(0.2))
                tableRow(rows[r], columns: columns, aligns: aligns, isHeader: false)
            }
        }
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.8)
        )
    }

    private func tableRow(_ cells: [String], columns: Int, aligns: [Alignment], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<columns, id: \.self) { c in
                let text = c < cells.count ? cells[c] : ""
                let align = c < aligns.count ? aligns[c] : .leading
                MarkdownInline(text)
                    .font(.system(size: 12, weight: isHeader ? .semibold : .regular))
                    .multilineTextAlignment(textAlignment(align))
                    .frame(maxWidth: .infinity, alignment: align)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(isHeader ? Color.primary.opacity(0.05) : Color.clear)

                if c < columns - 1 {
                    Divider()
                }
            }
        }
    }

    private func textAlignment(_ align: Alignment) -> TextAlignment {
        switch align {
        case .trailing: return .trailing
        case .center: return .center
        default: return .leading
        }
    }
}
