import AppKit
import Foundation

/// `FENRIR_SELFTEST=focus`: clicks the Find files field through the window (mouseDown/mouseUp via `sendEvent`),
/// types into it, and checks the text lands in the field and not in the terminal.
@MainActor
enum FocusSelfTest {
    static func run(_ model: AppModel) async {
        let repo = ProcessInfo.processInfo.environment["FENRIR_REPO"] ?? NSHomeDirectory()
        model.showPanel = true
        model.panelTab = .files
        model.add(name: "fenrir", path: repo, host: nil)
        await SelfTest.pause(3)
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }), let content = w.contentView,
              let session = model.selectedSession else { return SelfTest.log("FAIL no window or session") }
        w.makeKeyAndOrderFront(nil)
        let term = session.term.view
        _ = w.makeFirstResponder(term)
        func field(_ v: NSView) -> NSTextField? {
            if let f = v as? NSTextField, f.placeholderString?.hasPrefix("Find files") == true { return f }
            for s in v.subviews { if let f = field(s) { return f } }
            return nil
        }
        guard let f = field(content) else { return SelfTest.log("FAIL Find field not found in the view tree") }
        let center = f.convert(NSPoint(x: f.bounds.midX, y: f.bounds.midY), to: nil)
        func mouse(_ t: NSEvent.EventType) {
            if let e = NSEvent.mouseEvent(with: t, location: center, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { w.postEvent(e, atStart: false) }
        }
        func key(_ c: Character) {
            for t in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: w.windowNumber, context: nil, characters: String(c), charactersIgnoringModifiers: String(c),
                                            isARepeat: false, keyCode: 0) { w.postEvent(e, atStart: false) }
            }
        }
        let before = SelfTest.dump(model, session.id)
        mouse(.leftMouseDown); mouse(.leftMouseUp)
        await SelfTest.pause(0.5)
        let editor = w.firstResponder as? NSTextView
        SelfTest.log("after click: firstResponder=\(String(describing: w.firstResponder.map { Swift.type(of: $0) })) fieldEditor=\(editor?.isFieldEditor ?? false)")
        for c in "zqx" { key(c); await SelfTest.pause(0.15) }
        await SelfTest.pause(2.5) // poller ticks and re-renders must not take focus back
        for c in "w" { key(c); await SelfTest.pause(0.15) }
        await SelfTest.pause(0.5)
        let after = SelfTest.dump(model, session.id)
        let inField = model.findQuery == "zqxw"
        let leaked = after != before && after.contains("zqx")
        SelfTest.log("\(inField ? "PASS" : "FAIL") field value='\(model.findQuery)' (expected zqxw)")
        SelfTest.log("\(leaked ? "FAIL" : "PASS") terminal received nothing (typed text in buffer: \(leaked))")
        SelfTest.log("firstResponder now \(String(describing: w.firstResponder.map { Swift.type(of: $0) }))")
        // Esc returns focus to the terminal.
        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: w.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                    isARepeat: false, keyCode: 53) { w.postEvent(e, atStart: false) }
        await SelfTest.pause(0.5)
        SelfTest.log("\(w.firstResponder === term ? "PASS" : "FAIL") Esc returns focus to the terminal; query='\(model.findQuery)'")
    }
}
