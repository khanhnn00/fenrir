import AppKit
import Foundation

/// `FENRIR_SELFTEST=t023`: project cards with seeded states (synthetic hook events, not agent output) and the
/// ⌘T / ⌘N shortcuts sent through the app menu. Needs FENRIR_SHOTS_DIR.
@MainActor
enum ProjectCardSelfTest {
    private static var failed = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failed += 1 }
        SelfTest.log("\(ok ? "PASS" : "FAIL") \(name) \(detail)")
    }

    private static func find(_ menu: NSMenu?, key: String, flags: NSEvent.ModifierFlags) -> (NSMenu, Int)? {
        for (i, item) in (menu?.items ?? []).enumerated() {
            if item.keyEquivalent == key && item.keyEquivalentModifierMask == flags { return (menu!, i) }
            if let hit = find(item.submenu, key: key, flags: flags) { return hit }
        }
        return nil
    }

    /// Checks that ⌘<key> is bound to the menu item `title` and runs it. While the app is not frontmost (headless run)
    /// SwiftUI leaves the item disabled and without an action, so `fallback` runs what the item's closure does.
    private static func command(_ key: String, expecting title: String, fallback: () -> Void) -> Bool {
        guard let (menu, i) = find(NSApp.mainMenu, key: key, flags: .command) else { return false }
        let item = menu.items[i]
        guard item.title == title else { SelfTest.log("⌘\(key.uppercased()) is bound to \"\(item.title)\""); return false }
        if let action = item.action, NSApp.sendAction(action, to: item.target, from: item) {
            SelfTest.log("⌘\(key.uppercased()) -> \"\(title)\" via the menu item")
        } else {
            SelfTest.log("⌘\(key.uppercased()) -> \"\(title)\" bound; app inactive so the menu item is disabled, running its action directly")
            fallback()
        }
        return true
    }

    static func run(_ model: AppModel) async {
        let dir = ProcessInfo.processInfo.environment["FENRIR_SHOTS_DIR"] ?? NSTemporaryDirectory() + "fenrir-shots"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        model.showSidebar = true
        model.showPanel = false
        model.add(name: "acme", path: SelfTest.tempDir("fenrir-t023-acme"), host: nil)
        let acme = model.projects.first { $0.name == "acme" }!
        model.add(name: "gtm", path: SelfTest.tempDir("fenrir-t023-gtm"), host: nil)
        let gtm = model.projects.first { $0.name == "gtm" }!
        model.add(name: "fenrir", path: SelfTest.tempDir("fenrir-t023-fenrir"), host: nil)
        let fenrir = model.projects.first { $0.name == "fenrir" }!
        model.open(project: acme)
        await SelfTest.pause(2)
        check("one card per project, acme starts with 1 session", model.sessions(of: acme).count == 1)
        Screenshots.snapshot(dir + "/card-one-session.png")

        let tabsBefore = model.tabs.count
        let sessionsBefore = model.sessions.count
        check("cmd+T handled", command("t", expecting: "New Session") { if let p = model.activeProject { model.newSession(in: p) } })
        await SelfTest.pause(1)
        check("cmd+T adds a session to the current project", model.sessions(of: acme).count == 2 && model.sessions.count == sessionsBefore + 1
              && model.selectedSession?.projectID == acme.id && model.tabs.count == tabsBefore,
              "acme sessions=\(model.sessions(of: acme).count) tabs=\(model.tabs.count)")
        check("cmd+T again", command("t", expecting: "New Session") { if let p = model.activeProject { model.newSession(in: p) } })
        await SelfTest.pause(1)
        check("acme has 3 sessions", model.sessions(of: acme).count == 3)

        func ev(_ kind: EventKind, _ s: SessionItem, _ p: Project, msg: String? = nil, id: String? = nil, agents: [AgentInfo]? = nil, title: String? = nil, prompt: String? = nil) {
            model.handle(HookEvent(kind: kind, cwd: p.path, claudeSession: "seed-\(s.id)", fenrirSession: s.id, projectId: p.id, message: msg,
                                   tsMs: Int64(Date().timeIntervalSince1970 * 1000), agentId: id, agentType: id == nil ? nil : "worker", agents: agents, title: title, prompt: prompt, ordinal: nil, tmuxSession: nil))
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let ns = model.sessions(of: acme)
        ev(.working, ns[0], acme, title: "Fix Teams login redirect")
        ev(.working, ns[1], acme, prompt: "summarise the release notes")
        ev(.idle, ns[1], acme)
        let scan = [AgentInfo(id: "a1", desc: "Fix Teams login request", mtime: now), AgentInfo(id: "a2", desc: "Rebase the release branch", mtime: now - 70_000)]
        ev(.working, ns[2], acme, title: "Cơ chế lưu trữ conversation")
        ev(.subagentStart, ns[2], acme, id: "a1", agents: scan)
        ev(.subagentStart, ns[2], acme, id: "a2", agents: scan)
        ev(.idle, ns[2], acme)
        let g = model.sessions(of: gtm).first ?? { model.newSession(in: gtm); return model.sessions(of: gtm).first! }()
        ev(.needsInput, g, gtm, msg: "Claude needs your permission to use Bash", title: "Deploy the staging stack")
        model.select(sessionID: ns[0].id)
        await SelfTest.pause(1.5)
        check("titles", ns[0].displayTitle == "Fix Teams login redirect" && ns[1].displayTitle == "summarise the release notes", ns.map(\.displayTitle).joined(separator: " | "))
        check("session 3 shows 2 subagents", ns[2].state == .agentsRunning && ns[2].agents.count == 2, "state=\(ns[2].state.label) agents=\(ns[2].agents.count)")
        check("unseen idle session and project-level unread", ns[1].unread == 1 && g.unread == 1)
        Screenshots.snapshot(dir + "/card-three-sessions.png")

        UserDefaults.standard.set(true, forKey: "projectCollapsed.\(acme.id)")
        await SelfTest.pause(1)
        Screenshots.snapshot(dir + "/card-collapsed.png")
        UserDefaults.standard.set(false, forKey: "projectCollapsed.\(acme.id)")
        _ = fenrir

        let beforeNew = model.tabs.count
        check("cmd+N handled", command("n", expecting: "New Tab") { model.newTab() })
        await SelfTest.pause(1)
        check("cmd+N opens a new tab on the landing zone", model.tabs.count == beforeNew + 1 && model.activeMachine == nil && model.activeTabID == model.tabs.last?.id,
              "tabs=\(model.tabs.count) landing=\(model.activeMachine == nil)")
        Screenshots.snapshot(dir + "/new-tab-landing.png")
        SelfTest.log(failed == 0 ? "ALL PASS" : "\(failed) FAILED")
    }
}
