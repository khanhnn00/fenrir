import AppKit
import Foundation
import SwiftTerm

/// `FENRIR_SELFTEST=remote`: one throwaway tmux session on `FENRIR_MACHINE_HOST` (default example-host).
/// Resizes the window narrow -> wide -> narrow and logs local grid vs ssh/tmux sizes with the latency until
/// they match; then drags a selection with the mouse, copies it with the Copy action and logs the pasteboard,
/// and feeds an OSC 52 sequence. The tmux session is killed at the end.
@MainActor
enum RemoteSelfTest {
    private static let env = ProcessInfo.processInfo.environment
    private static var host: String { env["FENRIR_MACHINE_HOST"] ?? "example-host" }
    private static let project = "t021probe"

    private static func remote(_ cmd: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ControlMaster=auto",
                       "-o", "ControlPath=/tmp/fenrir-t021-%C", "-o", "ControlPersist=120", "--", host, cmd]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try? p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tmuxName() -> String {
        remote("tmux ls -F '#{session_name}' | grep '^fenrir-\(project)-' | head -1")
    }

    static func run(_ model: AppModel) async {
        let dir = env["FENRIR_SHOTS_DIR"] ?? SelfTest.tempDir("fenrir-shots")
        let tag = env["FENRIR_SHOT_TAG"] ?? "t021"
        model.add(name: "local", path: env["FENRIR_REPO"] ?? NSHomeDirectory(), host: nil)
        await SelfTest.pause(1.5)
        do { try model.addMachine(name: "", host: host) } catch { SelfTest.log("add machine failed: \(error)"); return }
        model.newTab()
        await SelfTest.pause(1)
        guard let machine = model.machines.first(where: { $0.host == host }) else { return }
        model.bind(tab: model.activeTabID, to: machine)
        model.add(name: project, path: "/tmp", host: host)
        let id = model.selectedSessionID!
        let view = model.selectedSession!.term.view
        await SelfTest.pause(1)
        guard let window = view.window else { SelfTest.log("no window"); return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        _ = window.makeFirstResponder(view)
        await SelfTest.pause(9)
        let name = tmuxName()
        SelfTest.log("tmux session: \(name)")
        guard name.hasPrefix("fenrir-\(project)-") else { SelfTest.log("no tmux session; abort"); return }
        defer { _ = remote("tmux kill-session -t '\(name)'"); SelfTest.log("killed \(name); left: [\(remote("tmux ls -F '#{session_name}' | grep '^fenrir-\(project)-'"))]") }

        func grid() -> String { let t = view.getTerminal(); return "\(t.cols)x\(t.rows)" }
        func tmuxSize() -> String {
            remote("tmux list-clients -t '\(name)' -F 'client=#{client_width}x#{client_height}'; tmux display -p -t '\(name)' 'window=#{window_width}x#{window_height} pane=#{pane_width}x#{pane_height}'")
                .replacingOccurrences(of: "\n", with: " ")
        }
        /// Local grid as client/window sizes tmux reports (window height excludes its status line).
        func matches(_ s: String) -> Bool {
            let t = view.getTerminal()
            return s.contains("client=\(t.cols)x\(t.rows) ") && s.contains("window=\(t.cols)x\(t.rows - 1) ")
        }
        func resize(_ w: CGFloat, _ h: CGFloat, _ label: String) async {
            let start = Date()
            var f = window.frame
            f.size = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: w, height: h)).size
            window.setFrame(f, display: true)
            var polls = 0, s = ""
            repeat { polls += 1; s = tmuxSize() } while !matches(s) && Date().timeIntervalSince(start) < 6
            let ok = matches(s)
            SelfTest.log("\(ok ? "PASS" : "FAIL") resize \(label) -> \(Int(w))x\(Int(h)): local=\(grid()) tmux: \(s) (\(String(format: "%.2f", Date().timeIntervalSince(start)))s, \(polls) polls)")
        }
        SelfTest.log("start: local=\(grid()) tmux: \(tmuxSize())")
        SelfTest.type(model, id, "echo resize-probe-$((6*7)); seq 1 60 | tail -5\n")
        await SelfTest.pause(1)
        await resize(1100, 640, "narrow")
        Screenshots.snapshot("\(dir)/\(tag)-narrow.png")
        await resize(1500, 900, "wide")
        Screenshots.snapshot("\(dir)/\(tag)-wide.png")
        await resize(1100, 640, "narrow again")
        await resize(1400, 800, "mid")
        // A drag in small steps, like grabbing the window corner.
        for i in 0..<12 {
            var f = window.frame; f.size.width += 15; f.size.height += 8; window.setFrame(f, display: true)
            _ = i
            await SelfTest.pause(0.03)
        }
        await SelfTest.pause(0.6)
        let s = tmuxSize()
        SelfTest.log("\(matches(s) ? "PASS" : "FAIL") after drag: local=\(grid()) tmux: \(s)")
        Screenshots.snapshot("\(dir)/\(tag)-after-drag.png")

        await copyCheck(model, id, view, window, dir, tag)
    }

    /// Drags across a printed marker with plain mouse events, copies, and feeds OSC 52.
    static func copyCheck(_ model: AppModel, _ id: Int64, _ view: TerminalView, _ window: NSWindow, _ dir: String, _ tag: String) async {
        // Copy: print a marker, drag across its row, Copy action, read the pasteboard.
        SelfTest.type(model, id, "clear; echo COPYMARK-alpha-beta-gamma\n")
        await SelfTest.pause(1.5)
        let t = view.getTerminal()
        var row = -1
        for r in 0..<t.rows {
            if let line = t.getLine(row: r), line.translateToString(trimRight: true).hasPrefix("COPYMARK") { row = r; break }
        }
        SelfTest.log("marker row=\(row) mouseMode=\(t.mouseMode) allowMouseReporting=\(view.allowMouseReporting)")
        guard row >= 0 else { SelfTest.log("screen: \(SelfTest.dump(model, id).split(separator: "\n").prefix(8).joined(separator: " | "))"); return }
        let cell = view.getOptimalFrameSize().height / CGFloat(t.rows)
        let cw = view.getOptimalFrameSize().width / CGFloat(t.cols)
        let y = view.bounds.height - (CGFloat(row) + 0.5) * cell
        NSPasteboard.general.clearContents()
        func mouse(_ kind: NSEvent.EventType, _ x: CGFloat, flags: NSEvent.ModifierFlags = []) {
            let pt = view.convert(NSPoint(x: x, y: y), to: nil)
            guard let ev = NSEvent.mouseEvent(with: kind, location: pt, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            let target = window.contentView?.hitTest(pt) ?? view
            switch kind {
            case .leftMouseDown: target.mouseDown(with: ev)
            case .leftMouseDragged: target.mouseDragged(with: ev)
            default: target.mouseUp(with: ev)
            }
        }
        var typed: [String] = []
        (model.selectedSession!.term).sendTap = { d in typed.append(d.map { String(format: "%02x", $0) }.joined()) }
        mouse(.leftMouseDown, 0.5 * cw)
        mouse(.leftMouseDragged, 0.5 * cw)
        for i in 1...10 { mouse(.leftMouseDragged, (0.5 + CGFloat(i)) * cw) }
        mouse(.leftMouseUp, 10.5 * cw)
        await SelfTest.pause(0.5)
        model.selectedSession!.term.sendTap = nil
        SelfTest.log("after drag: selection.active=\(view.selectionActive) text='\(view.getSelection() ?? "")' bytes sent to remote=\(typed.count)")
        Screenshots.snapshot("\(dir)/\(tag)-selected.png")
        let copyItem = NSApp.mainMenu?.items.compactMap { $0.submenu?.items.first { $0.title == "Copy" } }.first
        SelfTest.log("main menu Copy: \(copyItem.map { "key=\($0.keyEquivalent) enabled=\($0.isEnabled) action=\(String(describing: $0.action))" } ?? "missing"); context menu: \(view.menu?.items.map(\.title) ?? [])")
        // The menu item sends copy: down the responder chain of the key window; a headless run is not the active app, so deliver it to the first responder directly.
        let handled = window.firstResponder?.tryToPerform(#selector(NSText.copy(_:)), with: nil) ?? false
        SelfTest.log("app active=\(NSApp.isActive) keyWindow=\(window.isKeyWindow)")
        let pb = NSPasteboard.general.string(forType: .string) ?? ""
        SelfTest.log("after copy: firstResponder=\(String(describing: window.firstResponder.map { Swift.type(of: $0) })) isTerm=\(window.firstResponder === view) selectionActive=\(view.selectionActive) text=\(view.getSelection() ?? "nil")")
        SelfTest.log("\(pb.hasPrefix("COPYMARK") ? "PASS" : "FAIL") Copy action on the first responder: handled=\(handled) pasteboard='\(pb)'")

        // OSC 52 as tmux emits it (empty and `c` selection parameter).
        NSPasteboard.general.clearContents()
        view.feed(text: "\u{1b}]52;;\(Data("osc52-empty-param".utf8).base64EncodedString())\u{7}")
        await SelfTest.pause(0.3)
        SelfTest.log("\(NSPasteboard.general.string(forType: .string) == "osc52-empty-param" ? "PASS" : "FAIL") osc52 empty param: '\(NSPasteboard.general.string(forType: .string) ?? "")'")
        view.feed(text: "\u{1b}]52;c;\(Data("osc52-c".utf8).base64EncodedString())\u{7}")
        await SelfTest.pause(0.3)
        SelfTest.log("\(NSPasteboard.general.string(forType: .string) == "osc52-c" ? "PASS" : "FAIL") osc52 c param: '\(NSPasteboard.general.string(forType: .string) ?? "")'")
    }
}

/// `FENRIR_SELFTEST=mouse`: same selection/copy probe against a local tmux with mouse mode on (no host needed).
@MainActor
enum MouseSelfTest {
    static func run(_ model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        let dir = env["FENRIR_SHOTS_DIR"] ?? SelfTest.tempDir("fenrir-shots")
        let tag = env["FENRIR_SHOT_TAG"] ?? "t021"
        model.add(name: "mouse", path: SelfTest.tempDir("fenrir-mouse"), host: nil)
        let id = model.selectedSessionID!
        let view = model.selectedSession!.term.view
        await SelfTest.pause(3)
        guard let window = view.window else { SelfTest.log("no window"); return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        _ = window.makeFirstResponder(view)
        if env["FENRIR_PLAIN"] == nil {
            SelfTest.type(model, id, "tmux -L t021 -f /dev/null new -A -s t021 \\; set -g mouse on \\; set -g set-clipboard on\n")
            await SelfTest.pause(5)
        }
        if env["FENRIR_PLAIN"] == nil { await resizeCheck(view, window) }
        await RemoteSelfTest.copyCheck(model, id, view, window, dir, tag)
        if env["FENRIR_PLAIN"] == nil { SelfTest.type(model, id, "exit\n"); await SelfTest.pause(0.5) }
        _ = Process.launchedProcess(launchPath: "/usr/local/bin/tmux", arguments: ["-L", "t021", "kill-server"])
    }

    /// Window resizes while a local tmux client is attached: local grid vs the size tmux reports, and the delay until they agree.
    static func resizeCheck(_ view: TerminalView, _ window: NSWindow) async {
        func tmuxClient() -> String {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/local/bin/tmux")
            p.arguments = ["-L", "t021", "list-clients", "-F", "#{client_width}x#{client_height}"]
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            try? p.run(); let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for (w, h) in [(1100, 640), (1500, 900), (1100, 640), (1400, 800)] as [(CGFloat, CGFloat)] {
            let start = Date()
            var f = window.frame
            f.size = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: w, height: h)).size
            window.setFrame(f, display: true)
            let t = view.getTerminal()
            var s = ""
            repeat { s = tmuxClient() } while s != "\(t.cols)x\(t.rows)" && Date().timeIntervalSince(start) < 4
            SelfTest.log("\(s == "\(t.cols)x\(t.rows)" ? "PASS" : "FAIL") resize \(Int(w))x\(Int(h)): local=\(t.cols)x\(t.rows) tmux client=\(s) after \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        }
    }
}
