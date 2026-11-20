import AppKit
import Foundation

/// Seeds nav states and writes window screenshots (`FENRIR_SHOTS_DIR`). Seeded states use
/// synthetic hook events so every card variant is visible; they are not agent output.
@MainActor
enum Screenshots {
    static func run(_ model: AppModel) async {
        let dir = ProcessInfo.processInfo.environment["FENRIR_SHOTS_DIR"] ?? NSTemporaryDirectory() + "fenrir-shots"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let repo = ProcessInfo.processInfo.environment["FENRIR_REPO"] ?? NSHomeDirectory()
        for (name, path) in [("gtm", repo + "/.."), ("fenrir", repo), ("docs", NSHomeDirectory() + "/code/demo-docs")] {
            model.add(name: name, path: (path as NSString).standardizingPath, host: nil)
        }
        let gtm = model.projects.first { $0.name == "gtm" }!
        model.newSession(in: gtm)
        await SelfTest.pause(2.5)
        func ev(_ kind: EventKind, _ p: String, _ msg: String? = nil) {
            let proj = model.projects.first { $0.name == p }!
            let s = model.sessions(of: proj).first!
            model.handle(HookEvent(kind: kind, cwd: proj.path, claudeSession: "seed", fenrirSession: s.id, projectId: proj.id,
                                   message: msg, tsMs: Int64(Date().timeIntervalSince1970 * 1000) - 130_000, agentId: nil, agentType: nil, agents: nil, title: nil, prompt: nil, ordinal: nil, tmuxSession: nil))
        }
        ev(.working, "gtm")
        ev(.idle, "fenrir")
        ev(.needsInput, "docs", "Claude needs your permission to use Bash")
        ev(.needsInput, "docs", "Claude needs your permission to use Bash")
        model.select(sessionID: model.sessions(of: gtm).first!.id)
        SelfTest.type(model, model.selectedSessionID!, "ls\n")
        await SelfTest.pause(1.5)
        model.panelTab = .files
        await SelfTest.pause(1)
        snapshot(dir + "/nav-files.png")
        model.panelTab = .context
        await SelfTest.pause(1)
        snapshot(dir + "/context.png")
    }

    static func snapshot(_ path: String) {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let v = w.contentView?.superview,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { SelfTest.log("no window to capture"); return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        SelfTest.log("saved \(path)")
    }
}

extension Screenshots {
    /// What the window server actually composited for this window (not a fresh redraw of the view tree).
    static func compositedSnapshot(_ path: String) {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.boundsIgnoreFraming]) else { SelfTest.log("no composited capture"); return }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        SelfTest.log("saved composited \(path)")
    }
}
