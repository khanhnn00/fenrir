import AppKit
import Foundation

/// `FENRIR_SELFTEST=t027`: opens a .swift file as a tab, edits it, saves with the Save command and checks the disk,
/// then opens a PDF and an xlsx (FENRIR_T027_PDF, FENRIR_T027_XLSX) as Quick Look tabs. Needs FENRIR_SHOTS_DIR.
@MainActor
enum FileViewerSelfTest {
    private static var failed = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failed += 1 }
        SelfTest.log("\(ok ? "PASS" : "FAIL") \(name) \(detail)")
    }

    private static func textView(in v: NSView?) -> NSTextView? {
        guard let v else { return nil }
        if let t = v as? NSTextView { return t }
        for s in v.subviews { if let t = textView(in: s) { return t } }
        return nil
    }

    private static func shot(_ dir: String, _ name: String) {
        Screenshots.snapshot(dir + "/\(name).png")
        Screenshots.compositedSnapshot(dir + "/\(name)-composited.png")
    }

    static func run(_ model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        let dir = env["FENRIR_SHOTS_DIR"] ?? NSTemporaryDirectory() + "fenrir-shots"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let root = SelfTest.tempDir("fenrir-t027")
        let file = root + "/Hello.swift"
        let original = "import Foundation\n\n// greets the user\nfunc greet(_ name: String) -> String {\n    let n = 42\n    return \"Hello, \\(name) \\(n)\"\n}\n"
        try? original.write(toFile: file, atomically: true, encoding: .utf8)
        model.showSidebar = true
        model.showPanel = true
        model.add(name: "t027", path: root, host: nil)
        await SelfTest.pause(2)

        model.openFile(path: file, host: nil)
        await SelfTest.pause(1)
        let doc = model.shownDoc
        check("swift opens as an editable tab", doc?.kind == .text && doc?.text == original, "tabs=\(model.activeFiles.map(\.name))")
        let tv = textView(in: NSApp.windows.first { $0.isVisible }?.contentView)
        check("editor view is on screen", tv != nil)
        shot(dir, "t027-swift-open")
        tv?.setSelectedRange(NSRange(location: (tv?.string as NSString?)?.length ?? 0, length: 0))
        tv?.insertText("// edited\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        await SelfTest.pause(0.5)
        check("typing marks the tab unsaved", doc?.dirty == true)
        shot(dir, "t027-swift-edited")
        model.saveShownFile()
        await SelfTest.pause(1)
        let onDisk = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        check("Save writes the file", onDisk == original + "// edited\n" && doc?.dirty == false, "bytes=\(onDisk.utf8.count)")

        for (label, key) in [("pdf", "FENRIR_T027_PDF"), ("xlsx", "FENRIR_T027_XLSX")] {
            guard let p = env[key] else { check("\(label) path given", false, key); continue }
            model.openFile(path: p, host: nil)
            await SelfTest.pause(3)
            check("\(label) opens as a Quick Look tab", model.shownDoc?.kind == .preview && model.shownDoc?.path == p)
            shot(dir, "t027-\(label)")
        }
        check("three file tabs", model.activeFiles.count == 3, "\(model.activeFiles.map(\.name))")
        model.showTerminal()
        await SelfTest.pause(1)
        check("Terminal chip returns to the shell", model.shownDoc == nil)
        SelfTest.log(failed == 0 ? "ALL PASS" : "FAILED \(failed)")
    }
}
