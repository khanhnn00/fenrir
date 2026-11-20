import AppKit
import Quartz
import SwiftUI

/// Colours and regex passes for the editor; one generic pass set covers the usual languages.
enum Syntax {
    static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    static let base = NSColor(white: 0.1, alpha: 1)
    static let keyword = NSColor(red: 0.62, green: 0.12, blue: 0.62, alpha: 1)
    static let string = NSColor(red: 0.74, green: 0.2, blue: 0.1, alpha: 1)
    static let number = NSColor(red: 0.1, green: 0.38, blue: 0.75, alpha: 1)
    static let comment = NSColor(white: 0.5, alpha: 1)
    static let highlightLimit = 400_000

    private static let keywords = try! NSRegularExpression(pattern: "\\b(" + [
        "func", "fn", "def", "class", "struct", "enum", "impl", "trait", "protocol", "extension", "interface", "type", "let", "var", "const", "static",
        "if", "else", "elif", "guard", "switch", "case", "default", "for", "while", "loop", "in", "do", "try", "catch", "throw", "throws", "return",
        "break", "continue", "import", "from", "use", "mod", "pub", "private", "public", "internal", "async", "await", "self", "super", "this",
        "true", "false", "nil", "null", "None", "True", "False", "match", "where", "as", "is", "new", "package", "export", "function", "fi", "then", "esac"
    ].joined(separator: "|") + ")\\b")
    private static let numbers = try! NSRegularExpression(pattern: "\\b(0x[0-9a-fA-F]+|\\d+(\\.\\d+)?)\\b")
    private static let strings = try! NSRegularExpression(pattern: "\"(\\\\.|[^\"\\\\\\n])*\"|'(\\\\.|[^'\\\\\\n])*'")
    private static let slashComments = try! NSRegularExpression(pattern: "//[^\\n]*|/\\*[\\s\\S]*?\\*/")
    private static let hashComments = try! NSRegularExpression(pattern: "(?m)(^|\\s)#[^\\n]*")
    private static let dashComments = try! NSRegularExpression(pattern: "--[^\\n]*")

    static func apply(to storage: NSTextStorage, ext: String) {
        let all = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: base], range: all)
        if storage.length <= highlightLimit {
            let hash = ["py", "sh", "zsh", "bash", "yml", "yaml", "toml", "rb", "tf", "conf", "ini", "env", "gitignore", "md"].contains(ext)
            let dash = ["sql", "lua", "hs"].contains(ext)
            let s = storage.string
            func paint(_ re: NSRegularExpression, _ color: NSColor) {
                re.enumerateMatches(in: s, range: all) { m, _, _ in if let r = m?.range { storage.addAttribute(.foregroundColor, value: color, range: r) } }
            }
            if ext != "md" && ext != "txt" { paint(numbers, number); paint(keywords, keyword) }
            paint(strings, string)
            if hash { paint(hashComments, comment) } else if dash { paint(dashComments, comment) } else if ext != "md" && ext != "txt" { paint(slashComments, comment) }
        }
        storage.endEditing()
    }
}

/// NSTextView in a scroll view that keeps `doc.text` in sync and highlights after edits.
struct CodeEditor: NSViewRepresentable {
    @ObservedObject var doc: FileDoc

    final class Coordinator: NSObject, NSTextViewDelegate {
        let doc: FileDoc
        var pending: DispatchWorkItem?
        init(_ doc: FileDoc) { self.doc = doc }
        var ext: String { (doc.path as NSString).pathExtension.lowercased() }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            doc.text = tv.string
            pending?.cancel()
            let w = DispatchWorkItem { [weak tv, ext] in if let st = tv?.textStorage { Syntax.apply(to: st, ext: ext) } }
            pending = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: w)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(doc) }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSTextView.scrollableTextView()
        let tv = sv.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.usesFindBar = true
        tv.backgroundColor = .white
        tv.insertionPointColor = .black
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.typingAttributes = [.font: Syntax.font, .foregroundColor: Syntax.base]
        tv.string = doc.text
        Syntax.apply(to: tv.textStorage!, ext: context.coordinator.ext)
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? NSTextView, tv.string != doc.text else { return }
        let sel = tv.selectedRange()
        tv.string = doc.text
        Syntax.apply(to: tv.textStorage!, ext: context.coordinator.ext)
        tv.setSelectedRange(NSRange(location: min(sel.location, (doc.text as NSString).length), length: 0))
    }
}

struct QuickLookPane: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .normal)!
        v.previewItem = url as NSURL
        return v
    }
    func updateNSView(_ v: QLPreviewView, context: Context) {
        if (v.previewItem as? NSURL) as URL? != url { v.previewItem = url as NSURL }
    }
}

/// What the main area shows when a file tab is selected.
struct FileView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var doc: FileDoc

    var body: some View {
        VStack(spacing: 0) {
            if doc.changedOnDisk {
                banner("This file changed on disk.", action: "Reload") { doc.reload() }
            }
            if let e = doc.saveError {
                banner("Save failed: \(e)", action: "Dismiss") { doc.saveError = nil }
            }
            switch doc.kind {
            case .text: CodeEditor(doc: doc).id(doc.id)
            case .preview: QuickLookPane(url: doc.localURL).id(doc.id)
            }
        }
        .background(Color.white)
    }

    private func banner(_ text: String, action: String, _ run: @escaping () -> Void) -> some View {
        HStack(spacing: Space.s) {
            Text(text).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 0)
            Button(action, action: run).controlSize(.small)
        }
        .padding(.horizontal, Space.m).padding(.vertical, 6)
        .background(Theme.needsInput.opacity(0.18))
    }
}

/// The strip above the main area: the terminal plus one chip per open file.
struct FileStrip: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: Space.xs) {
            chip(icon: "terminal", title: "Terminal", dirty: false, active: model.shownFileID == nil) { model.showTerminal() }
            ForEach(model.activeFiles) { d in
                FileChip(doc: d, active: model.shownFileID == d.id)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.s).frame(height: 30)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func chip(icon: String, title: String, dirty: Bool, active: Bool, _ tap: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11))
            Text(title).font(.system(size: 12, weight: active ? .semibold : .regular))
        }
        .padding(.horizontal, 10).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(active ? Color.accentColor.opacity(0.14) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: tap)
    }
}

private struct FileChip: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var doc: FileDoc
    let active: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: doc.kind == .text ? "doc.text" : "eye").font(.system(size: 11))
            Text(doc.name).font(.system(size: 12, weight: active ? .semibold : .regular)).lineLimit(1)
            Spacer(minLength: 8)
            ZStack {
                if doc.dirty && !hover { Circle().fill(Color.primary.opacity(0.6)).frame(width: 7, height: 7) }
                Button { model.requestClose(file: doc) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain).opacity(hover || (active && !doc.dirty) ? 0.7 : 0)
            }
            .frame(width: 14, height: 14)
        }
        .padding(.horizontal, 10).padding(.vertical, 3).frame(minWidth: 110, maxWidth: 220)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(active ? Color.accentColor.opacity(0.14) : hover ? Color.primary.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.show(file: doc) }
        .onHover { hover = $0 }
        .help(doc.host.map { "\($0):\(doc.path)" } ?? doc.path)
    }
}
