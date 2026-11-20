import AppKit
import Foundation

/// `FENRIR_SELFTEST=t024`: ⌘W closes the session and moves to a sibling in the project, ⇧⌘W closes the tab.
@MainActor
enum CloseSelfTest {
    private static var failed = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failed += 1 }
        SelfTest.log("\(ok ? "PASS" : "FAIL") \(name) \(detail)")
    }

    private static func find(_ menu: NSMenu?, key: String, flags: NSEvent.ModifierFlags) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.keyEquivalent.lowercased() == key && item.keyEquivalentModifierMask == flags { return item }
            if let hit = find(item.submenu, key: key, flags: flags) { return hit }
        }
        return nil
    }

    /// Checks that the shortcut is bound to the menu item `title` and runs it; headless runs leave the item without an
    /// action, so `fallback` runs what its closure does.
    private static func press(_ key: String, _ flags: NSEvent.ModifierFlags, expecting title: String, fallback: () -> Void) -> Bool {
        guard let item = find(NSApp.mainMenu, key: key, flags: flags) else { return false }
        guard item.title == title else { SelfTest.log("shortcut is bound to \"\(item.title)\""); return false }
        if let action = item.action, NSApp.sendAction(action, to: item.target, from: item) { return true }
        fallback()
        return true
    }

    static func run(_ model: AppModel) async {
        model.add(name: "closer", path: SelfTest.tempDir("fenrir-t024-closer"), host: nil)
        let p = model.projects.first { $0.name == "closer" }!
        model.open(project: p)
        await SelfTest.pause(1.5)
        model.newSession(in: p); model.newSession(in: p)
        await SelfTest.pause(1)
        let ids = model.sessions(of: p).map(\.id)
        check("project has 3 sessions", ids.count == 3)
        model.select(sessionID: ids[1])
        let tabs = model.tabs.count
        let closeSession = { if let s = model.selectedSession { model.requestClose(s) } }

        check("cmd+W is Close Session", press("w", .command, expecting: "Close Session", fallback: closeSession))
        await SelfTest.pause(1)
        let left = model.sessions(of: p).map(\.id)
        check("middle closed, 2 left", left == [ids[0], ids[2]], "\(left)")
        check("next session selected", model.selectedSessionID == ids[2])
        check("tab still open", model.tabs.count == tabs)

        check("cmd+W on the last in order selects the previous", press("w", .command, expecting: "Close Session", fallback: closeSession))
        await SelfTest.pause(1)
        check("one left and selected", model.sessions(of: p).map(\.id) == [ids[0]] && model.selectedSessionID == ids[0])

        check("cmd+W on the only session", press("w", .command, expecting: "Close Session", fallback: closeSession))
        await SelfTest.pause(1)
        check("empty project state", model.sessions(of: p).isEmpty && model.selectedSession == nil && model.activeProject?.id == p.id
              && model.tabs.count == tabs, "tabs=\(model.tabs.count)")

        model.newTab()
        let withNew = model.tabs.count
        check("shift+cmd+W is Close Tab", press("w", [.command, .shift], expecting: "Close Tab") { model.closeTab(model.activeTabID) })
        await SelfTest.pause(0.5)
        check("shift+cmd+W closes the tab", model.tabs.count == withNew - 1, "tabs=\(model.tabs.count)")
        SelfTest.log(failed == 0 ? "ALL PASS" : "\(failed) FAILED")
    }
}
