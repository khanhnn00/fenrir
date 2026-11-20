import AppKit
import Foundation
import SwiftTerm

/// Headless checks driven by `FENRIR_SELFTEST`:
///  - `1`      two projects, one with two sessions; sessions survive switching.
///  - `claude` runs a real `claude -p` inside a Fenrir session and logs the state changes
///             the hooks cause (needs FENRIR_REPO, the repo root holding scripts/fenrir-hook.cjs).
///  - `subagent` real claude session that launches a background subagent; logs Agents running then Idle.
///  - `shots`  seeds nav states and saves window screenshots to FENRIR_SHOTS_DIR.
@MainActor
enum SelfTest {
    static var started = false

    static func log(_ s: String) { FileHandle.standardError.write(Data("selftest: \(s)\n".utf8)) }
    static func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    static func type(_ model: AppModel, _ id: Int64, _ text: String) {
        do { try model.core.writeSession(id: id, data: Data(text.utf8)) } catch { log("write \(id) failed: \(error)") }
    }

    static func dump(_ model: AppModel, _ id: Int64) -> String {
        guard let s = model.sessions.first(where: { $0.id == id }) else { return "" }
        return String(decoding: s.term.view.getTerminal().getBufferAsData(), as: UTF8.self)
    }

    static func tempDir(_ name: String) -> String {
        let d = NSTemporaryDirectory() + name
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    static func runIfRequested(_ model: AppModel) {
        guard let mode = ProcessInfo.processInfo.environment["FENRIR_SELFTEST"], !started else { return }
        started = true
        Task { @MainActor in
            switch mode {
            case "claude": await claude(model)
            case "subagent": await SubagentSelfTest.run(model)
            case "shots": await Screenshots.run(model)
            case "demo": await DemoShots.run(model)
            case "t023": await ProjectCardSelfTest.run(model)
            case "t024": await CloseSelfTest.run(model)
            case "t027": await FileViewerSelfTest.run(model)
            case "t028": await QuitSelfTest.run(model)
            case "org": await OrgSelfTest.run(model)
            case "layout": await LayoutSelfTest.run(model)
            case "focus": await FocusSelfTest.run(model)
            case "panel": await PanelSelfTest.run(model)
            case "t029": await ForwardSelfTest.run(model)
            case "dragout": await DragOutSelfTest.run(model)
            case "sftp": await SftpSelfTest.run(model)
            case "scroll": await scroll(model)
            case "fill": await fill(model)
            case "cursor": await CursorSelfTest.run(model)
            case "optdel": await optDel(model)
            case "scrollreal": await scrollReal(model)
            case "remote": await RemoteSelfTest.run(model)
            case "mouse": await MouseSelfTest.run(model)
            case "machines-seed": await MachinesSelfTest.seed(model)
            case "machines-check": await MachinesSelfTest.check(model)
            case "restore-seed": await restoreSeed(model)
            case "restore-check": await restoreCheck(model)
            default: await sessions(model)
            }
            exit(0)
        }
    }

    private static func sessions(_ model: AppModel) async {
        model.add(name: "alpha", path: tempDir("fenrir-a"), host: nil)
        let a1 = model.selectedSessionID!
        await pause(3)
        type(model, a1, "echo A1_$$; pwd -P\n")
        model.add(name: "beta", path: tempDir("fenrir-b"), host: nil)
        let b1 = model.selectedSessionID!
        await pause(1.5)
        type(model, b1, "echo B1_$$\n")
        model.newSession(in: model.projects.first { $0.name == "alpha" }!)
        let a2 = model.selectedSessionID!
        await pause(1.5)
        type(model, a2, "echo A2_$$\n")
        model.select(sessionID: a1)
        type(model, a1, "echo A1_again_$$\n")
        await pause(1)
        log("ids a1=\(a1) b1=\(b1) a2=\(a2) alive=\(model.core.sessionAlive(id: a1)),\(model.core.sessionAlive(id: b1)),\(model.core.sessionAlive(id: a2))")
        for id in [a1, b1, a2] { log("--- session \(id) ---\n\(dump(model, id))") }
    }

    /// Dense output, real-window screenshots (screencapture), then synthetic wheel events sent through the window.
    private static func scroll(_ model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        let dir = env["FENRIR_SHOTS_DIR"] ?? tempDir("fenrir-shots")
        let tag = env["FENRIR_SHOT_TAG"] ?? "after"
        model.add(name: "scroll-probe", path: tempDir("fenrir-scroll"), host: nil)
        let id = model.selectedSessionID!
        let view = model.selectedSession!.term.view
        await pause(3)
        type(model, id, "clear; ls -la /usr/bin | head -300; printf '\\033[7m inverse \\033[0m \\033[4munderline\\033[0m \\033[41m red bg \\033[0m\\n'; for i in 1 2 3; do printf '\\033[48;5;238m  bg row %s  \\033[0m\\n' $i; done; printf '┌────────┐\\n│ box    │\\n└────────┘\\n'\n")
        await pause(2)
        func yDisp() -> Int { view.getTerminal().buffer.yDisp }
        func shot(_ n: String) {
            // screencapture needs Screen Recording permission, so render the view hierarchy instead.
            guard let host = view.window?.contentView?.superview,
                  let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(tag)-\(n).png"))
            // The terminal view alone, drawn onto transparent pixels and then composited over its layer background,
            // which is how its backing store reaches the screen (cacheDisplay of the window pre-fills the pixels).
            if let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
               case let _ = (out.size = view.bounds.size),
               let gc = NSGraphicsContext(bitmapImageRep: out) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = gc
                view.draw(view.bounds)
                NSGraphicsContext.restoreGraphicsState()
                let flat = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: out.pixelsWide, pixelsHigh: out.pixelsHigh, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                flat.size = view.bounds.size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: flat)
                view.nativeBackgroundColor.setFill()
                NSRect(origin: .zero, size: view.bounds.size).fill()
                out.draw(in: NSRect(origin: .zero, size: view.bounds.size))
                NSGraphicsContext.restoreGraphicsState()
                try? flat.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(tag)-\(n)-term.png"))
            }
            log("saved \(n)")
        }
        var first = true
        func wheel(_ dy: Int32) {
            guard let w = view.window, let content = w.contentView,
                  let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0),
                  let ev = NSEvent(cgEvent: cg) else { return }
            // Deliver to whatever view is under a point over the terminal, as the window would for a real event.
            let pt = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: content)
            let target = content.hitTest(pt)
            if first { log("hitTest -> \(String(describing: target.map { Swift.type(of: $0) }))"); first = false }
            (target ?? view).scrollWheel(with: ev)
        }
        log("rows=\(view.getTerminal().rows) yDisp=\(yDisp()) scrollPos=\(view.scrollPosition) canScroll=\(view.canScroll)")
        shot("bottom")
        let before = yDisp()
        for _ in 0..<10 { wheel(40); await pause(0.05) }
        log("yDisp after wheel up: \(before) -> \(yDisp())")
        await pause(0.5)
        shot("scrolled")
        // New output while scrolled back must not move the viewport.
        let held = yDisp()
        type(model, id, "ls /usr/bin | head -40\n")
        await pause(1.5)
        log("yDisp while output arrives: \(held) -> \(yDisp())")
        shot("scrolled-after-output")
        // Typing returns to the live screen.
        view.terminalDelegate?.send(source: view, data: ArraySlice([UInt8]("x".utf8)))
        await pause(0.5)
        log("yDisp after typing: \(yDisp()) scrollPos=\(view.scrollPosition)")
    }

    /// Posts real scroll events to this process (they travel the WindowServer queue, NSApp, NSWindow.sendEvent, hitTest)
    /// over the terminal, once in a plain shell and once inside the claude TUI, and logs the scroll offsets.
    private static func scrollReal(_ model: AppModel) async {
        model.add(name: "scrollreal", path: ProcessInfo.processInfo.environment["FENRIR_REPO"] ?? tempDir("fenrir-scrollreal"), host: nil)
        let id = model.selectedSessionID!
        let item = model.selectedSession!
        let view = item.term.view
        await pause(3)
        view.window?.orderFrontRegardless()
        view.window?.makeKey()
        await pause(6)
        func post(_ dy: Int32) {
            guard let w = view.window, let screen = w.screen else { return }
            let sr = w.convertToScreen(view.convert(view.bounds, to: nil))
            let cgPt = CGPoint(x: sr.midX - 40, y: screen.frame.maxY - sr.midY)
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0) else { return }
            cg.location = cgPt
            guard let ev = NSEvent(cgEvent: cg), let content = w.contentView else { return }
            // Same dispatch NSWindow performs: hitTest the content view, then deliver to the view found.
            (content.hitTest(content.convert(view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil), from: nil)) ?? view).scrollWheel(with: ev)
        }
        func state(_ tag: String) {
            let t = view.getTerminal()
            log("\(tag): yDisp=\(t.buffer.yDisp) scrollPos=\(view.scrollPosition) mouse=\(t.mouseMode) canScroll=\(view.canScroll) wheelReports=\(item.term.wheelReports) screenHash=\(dump(model, id).hashValue % 100000)")
        }
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            let hit = e.window?.contentView?.hitTest(e.locationInWindow).map { "\(Swift.type(of: $0))" } ?? "nil"
            log("scrollWheel event win=\(e.window?.windowNumber ?? -1) dy=\(e.deltaY) sdy=\(e.scrollingDeltaY) precise=\(e.hasPreciseScrollingDeltas) loc=\(e.locationInWindow) hit=\(hit)")
            return e
        }
        if let w = view.window { log("window frame=\(w.frame) key=\(w.isKeyWindow) visible=\(w.isVisible) occluded=\(!w.occlusionState.contains(.visible)) fr=\(String(describing: w.firstResponder.map { Swift.type(of: $0) }))") }
        type(model, id, "clear; for i in $(seq 1 200); do echo line $i; done\n")
        await pause(2)
        state("plain bottom")
        for _ in 0..<10 { post(30); await pause(0.05) }
        await pause(0.5)
        state("plain after wheel up")
        for _ in 0..<10 { post(-30); await pause(0.05) }
        await pause(0.5)
        state("plain after wheel down")
        type(model, id, "clear; claude\n")
        await pause(10)
        state("claude idle")
        type(model, id, "Write the numbers from 1 to 120, one per line, nothing else\r")
        await pause(25)
        state("claude after answer")
        for _ in 0..<10 { post(30); await pause(0.05) }
        await pause(0.5)
        state("claude after wheel up")
        log("--- screen ---\n\(dump(model, id).suffix(1500))")
    }

    /// Terminal height vs rows vs the PTY's own idea of the size (`stty size`), then claude's status line position.
    private static func fill(_ model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        let dir = env["FENRIR_SHOTS_DIR"] ?? tempDir("fenrir-shots")
        let tag = env["FENRIR_SHOT_TAG"] ?? "after"
        model.add(name: "fill-a", path: tempDir("fenrir-fill-a"), host: nil)
        let a = model.selectedSessionID!
        let view = model.selectedSession!.term.view
        await pause(3)
        func measure(_ label: String, _ v: TerminalView, _ id: Int64) async {
            let t = v.getTerminal()
            let cellH = v.getOptimalFrameSize().height / CGFloat(max(t.rows, 1))
            let sup = v.superview?.bounds.height ?? -1
            let w = v.window
            type(model, id, "clear; echo SZ=$(stty size)\n")
            await pause(1)
            let sz = dump(model, id).components(separatedBy: "\n").first { $0.hasPrefix("SZ=") } ?? "?"
            log("\(label): viewH=\(v.frame.height) boundsH=\(v.bounds.height) superH=\(sup) cellH=\(cellH) rows=\(t.rows) view/cell=\(v.frame.height / cellH) leftover=\(v.frame.height - cellH * CGFloat(t.rows)) \(sz) win=\(w?.frame.size ?? .zero) layoutRect=\(w?.contentLayoutRect ?? .zero)")
        }
        await measure("new session", view, a)
        if let w = view.window {
            var f = w.frame; f.size.height -= 137; f.size.width -= 61
            w.setFrame(f, display: true)
            await pause(1.5)
            await measure("after window resize", view, a)
        }
        model.newSession(in: model.projects.first { $0.name == "fill-a" }!)
        let b = model.selectedSessionID!
        let v2 = model.selectedSession!.term.view
        await pause(3)
        await measure("second session", v2, b)
        model.select(sessionID: a)
        await pause(1)
        await measure("switch back", view, a)
        let claudeDir = env["FENRIR_CLAUDE_DIR"] ?? env["FENRIR_REPO"] ?? tempDir("fenrir-fill-claude")
        model.add(name: "fill-claude", path: claudeDir, host: nil)
        let c = model.selectedSessionID!
        let v3 = model.selectedSession!.term.view
        await pause(3)
        type(model, c, "claude\n")
        await pause(12)
        let t3 = v3.getTerminal()
        log("claude: rows=\(t3.rows) viewH=\(v3.frame.height)")
        let lines = String(decoding: t3.getBufferAsData(kind: .alt), as: UTF8.self).components(separatedBy: "\n")
        log("claude alt screen has \(lines.count) lines; last non-empty index=\(lines.lastIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? -1)")
        for (i, l) in lines.enumerated().suffix(6) { log("alt[\(i)] \(l)") }
        for r in 0..<t3.rows {
            guard t3.getCharacter(col: 0, row: r) == "❯" else { continue }
            let cells = (0...8).compactMap { c -> String? in
                guard let d = t3.getCharData(col: c, row: r) else { return nil }
                return "'\(d.getCharacter())' style=\(d.attribute.style.rawValue) fg=\(d.attribute.fg) bg=\(d.attribute.bg)"
            }
            log("input row \(r): \(cells.joined(separator: " | "))")
        }
        Screenshots.snapshot("\(dir)/\(tag)-fill-claude.png")
        type(model, c, "\u{3}\u{3}")
    }

    /// Option+Delete: bytes the key sends, bytes the shell answers with, and what the buffer shows afterwards.
    private static func optDel(_ model: AppModel) async {
        model.add(name: "optdel", path: tempDir("fenrir-optdel"), host: nil)
        let id = model.selectedSessionID!
        let item = model.selectedSession!.term
        let view = item.view
        await pause(3)
        var raw = Data()
        item.rawTap = { raw.append($0) }
        var sent = [UInt8]()
        item.sendTap = { sent.append(contentsOf: $0) }
        type(model, id, "clear\n")
        await pause(1)
        type(model, id, "echo alpha beta gamma")
        await pause(1)
        func row() -> String {
            let t = view.getTerminal()
            let r = t.buffer.y
            let text = (0..<t.cols).map { String(t.getCharacter(col: $0, row: r) ?? " ") }.joined()
            return "cursor=(\(t.buffer.x),\(r)) row='\(text.trimmingCharacters(in: .whitespaces))'"
        }
        log("before: \(row())")
        let shots = ProcessInfo.processInfo.environment["FENRIR_SHOTS_DIR"] ?? tempDir("fenrir-shots")
        Screenshots.snapshot(shots + "/optdel-before.png")
        Screenshots.compositedSnapshot(shots + "/optdel-before-composited.png")
        raw.removeAll()
        guard let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                                        context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51) else { return }
        view.keyDown(with: ev)
        await pause(1)
        log("key bytes sent: \(sent.map { String(format: "%02x", $0) }.joined(separator: " "))")
        log("shell reply bytes: \(String(decoding: raw, as: UTF8.self).debugDescription)")
        log("after: \(row())")
        Screenshots.snapshot(shots + "/optdel-after.png")
        Screenshots.compositedSnapshot(shots + "/optdel-after-composited.png")
        // Same key inside the claude input box.
        let env = ProcessInfo.processInfo.environment
        model.add(name: "optdel-claude", path: env["FENRIR_CLAUDE_DIR"] ?? tempDir("fenrir-optdel-claude"), host: nil)
        let cid = model.selectedSessionID!
        let citem = model.selectedSession!.term
        let cview = citem.view
        await pause(3)
        type(model, cid, "claude\n")
        await pause(12)
        type(model, cid, "alpha beta gamma")
        await pause(2)
        func crow() -> String {
            let t = cview.getTerminal()
            return (0..<t.rows).compactMap { r -> String? in
                let s = (0..<t.cols).map { String(t.getCharacter(col: $0, row: r) ?? " ") }.joined().trimmingCharacters(in: .whitespaces)
                return s.hasPrefix("❯") ? "row \(r): \(s) cursor=(\(cview.getTerminal().buffer.x),\(cview.getTerminal().buffer.y))" : nil
            }.joined(separator: " / ")
        }
        log("claude before: \(crow())")
        Screenshots.compositedSnapshot(shots + "/optdel-claude-before-composited.png")
        var craw = Data(), csent = [UInt8]()
        citem.rawTap = { craw.append($0) }
        citem.sendTap = { csent.append(contentsOf: $0) }
        guard let cev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0, windowNumber: cview.window?.windowNumber ?? 0,
                                         context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51) else { return }
        cview.keyDown(with: cev)
        await pause(1.5)
        log("claude key bytes sent: \(csent.map { String(format: "%02x", $0) }.joined(separator: " "))")
        log("claude reply bytes: \(String(decoding: craw, as: UTF8.self).debugDescription)")
        log("claude after: \(crow())")
        // Held key: repeated Option+Delete at key-repeat speed.
        type(model, cid, " xin chào các bạn đây là tiếng Việt ươ")
        await pause(2)
        log("claude repeat before: \(crow())")
        for _ in 0..<3 { cview.keyDown(with: cev); await pause(0.03) }
        await pause(1.5)
        log("claude repeat after: \(crow())")
        Screenshots.compositedSnapshot(shots + "/optdel-claude-repeat-composited.png")
        Screenshots.compositedSnapshot(shots + "/optdel-claude-after-composited.png")
        type(model, cid, "\u{3}\u{3}")
    }

    /// Restore check, part 1: two sessions in two projects, one with a real claude conversation. Waits to be killed.
    private static func restoreSeed(_ model: AppModel) async {
        guard let home = ProcessInfo.processInfo.environment["FENRIR_HOME"], let repo = ProcessInfo.processInfo.environment["FENRIR_REPO"] else { log("FENRIR_REPO and FENRIR_HOME required"); return }
        let settings = home + "/hook-settings.json"
        let cmd = "node \(repo)/scripts/fenrir-hook.cjs"
        let hooks = ["UserPromptSubmit", "Stop", "Notification"].map { "\"\($0)\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"\(cmd)\"}]}]" }
        try? "{\"hooks\":{\(hooks.joined(separator: ","))}}".write(toFile: settings, atomically: true, encoding: .utf8)
        model.add(name: "alpha", path: tempDir("fenrir-ra"), host: nil)
        let a = model.selectedSessionID!
        model.add(name: "beta", path: ProcessInfo.processInfo.environment["FENRIR_CLAUDE_DIR"] ?? repo, host: nil)
        let b = model.selectedSessionID!
        await pause(3)
        type(model, a, "for i in $(seq 1 60); do echo alpha-line-$i; done\n")
        type(model, b, "echo beta-shell-marker; claude --settings \(settings)\n")
        await pause(10)
        type(model, b, "Remember the secret word pineapple-42 and reply with just OK\r")
        let item = model.sessions.first { $0.id == b }!
        for _ in 0..<120 {
            await pause(0.5)
            if item.state == .idle && item.lastMessage != nil { break }
        }
        log("seed: screen=\(dump(model, b).suffix(700))")
        log("seed: claudeSession=\(item.claudeSession ?? "nil") state=\(item.state.label)")
        model.select(sessionID: a)
        await pause(12)
        log("seed: saved, waiting to be killed; selected=\(a)")
        await pause(300)
    }

    /// Restore check, part 2: logs what came back after a relaunch.
    private static func restoreCheck(_ model: AppModel) async {
        await pause(25)
        log("check: \(model.sessions.count) sessions, selected=\(model.selectedSessionID.map(String.init) ?? "nil")")
        for s in model.sessions {
            let name = model.projects.first { $0.id == s.projectID }?.name ?? "?"
            log("check: session \(s.id) project=\(name) ordinal=\(s.ordinal) claude=\(s.claudeSession ?? "nil")")
            log("check: alt=\(s.term.view.isAlternateScreen) mouse=\(s.term.view.getTerminal().mouseMode) altText=\(String(decoding: s.term.view.getTerminal().getBufferAsData(kind: .alt), as: UTF8.self).suffix(600))")
            log("--- \(name) screen ---\n\(String(dump(model, s.id).suffix(900)))")
        }
    }

    private static func claude(_ model: AppModel) async {
        guard let repo = ProcessInfo.processInfo.environment["FENRIR_REPO"],
              let home = ProcessInfo.processInfo.environment["FENRIR_HOME"] else { log("FENRIR_REPO and FENRIR_HOME required"); return }
        let settings = home + "/hook-settings.json"
        let cmd = "node \(repo)/scripts/fenrir-hook.cjs"
        let hooks = ["UserPromptSubmit", "Stop", "Notification"].map { "\"\($0)\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"\(cmd)\"}]}]" }
        try? "{\"hooks\":{\(hooks.joined(separator: ","))}}".write(toFile: settings, atomically: true, encoding: .utf8)
        model.add(name: "claude-probe", path: tempDir("fenrir-claude-probe"), host: nil)
        let id = model.selectedSessionID!
        let item = model.selectedSession!
        model.select(sessionID: id)
        await pause(3)
        log("before: state=\(item.state.label) unread=\(item.unread)")
        type(model, id, "claude --settings \(settings) -p 'say hi'\n")
        var last = item.state.label
        for _ in 0..<240 {
            await pause(0.5)
            if item.state.label != last || item.unread > 0 { last = item.state.label; log("state=\(last) unread=\(item.unread) msg=\(item.lastMessage ?? "-")") }
            if item.state == .idle && item.lastMessage != nil { break }
        }
        log("--- terminal ---\n\(dump(model, id))")
    }
}
