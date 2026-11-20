import AppKit
import Foundation
import SwiftTerm

/// `FENRIR_SELFTEST=cursor`: the caret keeps blinking through scroll, click, selection and session switches,
/// the glyph under a block cursor stays readable, DECSCUSR shapes are honoured and an unfocused terminal
/// shows a hollow box. Optional: FENRIR_CLAUDE_DIR (a claude-trusted dir) renders claude's input suggestion.
@MainActor
enum CursorSelfTest {
    static func run(_ model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        let dir = env["FENRIR_SHOTS_DIR"] ?? SelfTest.tempDir("fenrir-shots")
        let tag = env["FENRIR_SHOT_TAG"] ?? "after"
        model.add(name: "cursor-a", path: SelfTest.tempDir("fenrir-cursor-a"), host: nil)
        let a = model.selectedSessionID!
        let view = model.selectedSession!.term.view
        await SelfTest.pause(3)
        NSApp.activate(ignoringOtherApps: true)
        view.window?.makeKeyAndOrderFront(nil)
        _ = view.window?.makeFirstResponder(view)
        await SelfTest.pause(0.5)
        if !(view.window?.isKeyWindow ?? false) { TerminalView.caretIgnoresKeyWindow(true); SelfTest.log("window is not key (another app is frontmost): treating first responder as focused") }
        SelfTest.type(model, a, "seq 1 200\n")
        await SelfTest.pause(1)

        /// Samples the painted state every 50 ms; reports toggles over the window.
        func sample(_ label: String, _ seconds: Double = 3, _ expectBlink: Bool = true, _ v: TerminalView? = nil) async {
            let v = v ?? view
            for _ in 0..<40 where !v.caretIsActive && (expectBlink || label.hasPrefix("after")) { v.window?.makeKeyAndOrderFront(nil); _ = v.window?.makeFirstResponder(v); await SelfTest.pause(0.05) }
            var last = v.caretIsPainted, toggles = 0, on = 0, n = 0
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                await SelfTest.pause(0.05)
                let now = v.caretIsPainted
                if now != last { toggles += 1; last = now }
                if now { on += 1 }
                n += 1
            }
            let ok = expectBlink ? toggles >= 4 : toggles == 0
            SelfTest.log("\(ok ? "PASS" : "FAIL") \(label): active=\(v.caretIsActive) toggles=\(toggles) paintedFrac=\(String(format: "%.2f", Double(on) / Double(max(n, 1)))) key=\(v.window?.isKeyWindow ?? false) fr=\(v.window?.firstResponder === v) yDisp=\(v.getTerminal().buffer.yDisp)")
        }
        func wheel(_ dy: Int32) {
            guard let content = view.window?.contentView,
                  let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0),
                  let ev = NSEvent(cgEvent: cg) else { return }
            let pt = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: content)
            (content.hitTest(pt) ?? view).scrollWheel(with: ev)
        }
        func click(count: Int = 1) {
            guard let w = view.window, let content = w.contentView else { return }
            let pt = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: content)
            let target = content.hitTest(pt) ?? view
            for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let ev = NSEvent.mouseEvent(with: kind, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1) {
                    kind == .leftMouseDown ? target.mouseDown(with: ev) : target.mouseUp(with: ev)
                }
            }
        }

        await sample("idle at bottom")
        for _ in 0..<10 { wheel(40); await SelfTest.pause(0.05) }
        await sample("after wheel up (cursor scrolled out of view, not painted)", 1.5, false)
        for _ in 0..<10 { wheel(-40); await SelfTest.pause(0.05) }
        await sample("after wheel back down")
        click()
        await sample("after click")
        click(count: 2)
        await sample("after double click (word selection)")
        view.getTerminal().updateFullScreen()
        model.newSession(in: model.projects.first { $0.name == "cursor-a" }!)
        await SelfTest.pause(2)
        let v2 = model.selectedSession!.term.view
        await sample("second session", 3, true, v2)
        model.select(sessionID: a)
        await SelfTest.pause(0.5)
        _ = view.window?.makeFirstResponder(view)
        await sample("after switching back")
        SelfTest.type(model, a, "echo typing")
        await sample("after typing")

        // Readable glyph: faint text under the cursor on the light theme.
        SelfTest.type(model, a, "\u{15}clear; printf '\\033[2mtry \"create a util\"\\033[0m\\033[17D'\n")
        await SelfTest.pause(1)
        for _ in 0..<40 where !view.caretIsPainted { await SelfTest.pause(0.05) }
        Screenshots.snapshot("\(dir)/\(tag)-cursor-faint-block-on.png")
        for _ in 0..<40 where view.caretIsPainted { await SelfTest.pause(0.05) }
        Screenshots.snapshot("\(dir)/\(tag)-cursor-faint-block-off.png")

        // DECSCUSR: 2 steady block, 4 steady underline, 6 steady bar, 5 blinking bar.
        for (code, name, blink) in [(2, "steady block", false), (4, "steady underline", false), (6, "steady bar", false), (5, "blinking bar", true), (1, "blinking block", true)] {
            view.feed(text: "\u{1b}[\(code) q")
            await SelfTest.pause(0.3)
            await sample("DECSCUSR \(code) \(name)", 2, blink)
            for _ in 0..<40 where !view.caretIsPainted { await SelfTest.pause(0.05) }
            Screenshots.snapshot("\(dir)/\(tag)-cursor-decscusr-\(code).png")
        }

        // Unfocused: hollow, steady.
        _ = view.window?.makeFirstResponder(nil)
        await SelfTest.pause(0.3)
        await sample("unfocused (hollow, steady)", 2, false)
        Screenshots.snapshot("\(dir)/\(tag)-cursor-unfocused.png")
        _ = view.window?.makeFirstResponder(view)

        if let claudeDir = env["FENRIR_CLAUDE_DIR"] {
            model.add(name: "cursor-claude", path: claudeDir, host: nil)
            let c = model.selectedSessionID!
            let cv = model.selectedSession!.term.view
            await SelfTest.pause(3)
            _ = view.window?.makeFirstResponder(cv)
            SelfTest.type(model, c, "claude\n")
            await SelfTest.pause(12)
            await sample("claude TUI", 3, true, cv)
            for _ in 0..<40 where !cv.caretIsPainted { await SelfTest.pause(0.05) }
            Screenshots.snapshot("\(dir)/\(tag)-cursor-claude-suggestion-on.png")
            SelfTest.type(model, c, "\u{3}\u{3}")
        }
    }
}
