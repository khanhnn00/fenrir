import SwiftUI

/// Small block renderer: headings, bullets, fenced code, rules, paragraphs; inline styles via AttributedString.
struct MarkdownView: View {
    let text: String

    private enum Block {
        case heading(Int, String), bullet(Int, String), code(String), rule, paragraph(String)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var para: [String] = []
        var code: [String]?
        func flush() { if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] } }
        for raw in text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression).components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
            } else if code != nil {
                code?.append(raw)
            } else if line.isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                flush()
                let level = line.prefix { $0 == "#" }.count
                out.append(.heading(min(level, 3), String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
            } else if line == "---" || line == "***" {
                flush(); out.append(.rule)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                let indent = (raw.prefix { $0 == " " }.count) / 2
                out.append(.bullet(indent, String(line.dropFirst(2))))
            } else {
                para.append(line)
            }
        }
        flush()
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .heading(let l, let t):
                    inline(t).font(.system(size: l == 1 ? 17 : l == 2 ? 14 : 12.5, weight: .semibold)).padding(.top, l == 1 ? 0 : 6)
                case .bullet(let i, let t):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        inline(t).font(.system(size: 12))
                    }.padding(.leading, CGFloat(i) * 12)
                case .code(let c):
                    Text(c).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                case .rule:
                    Divider()
                case .paragraph(let t):
                    inline(t).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.85))
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { return Text(a) }
        return Text(s)
    }
}
