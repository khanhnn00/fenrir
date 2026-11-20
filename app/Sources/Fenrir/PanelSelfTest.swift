import AppKit
import Foundation

/// `FENRIR_SELFTEST=panel`: right panel (Files short/long tree, Find, Context) in light and dark, as the window
/// server composited it. Writes `panel-<tag>-<scheme>.png`; needs FENRIR_REPO and FENRIR_SHOTS_DIR.
@MainActor
enum PanelSelfTest {
    static func run(_ model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        let dir = env["FENRIR_SHOTS_DIR"] ?? NSTemporaryDirectory() + "fenrir-shots"
        let prefix = env["FENRIR_PANEL_PREFIX"] ?? "panel"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let repo = env["FENRIR_REPO"] ?? NSHomeDirectory()
        model.showSidebar = true
        model.showPanel = true
        model.add(name: "short", path: repo + "/design", host: nil)
        model.add(name: "long", path: (repo as NSString).deletingLastPathComponent, host: nil)
        await SelfTest.pause(2)
        for scheme in ["light", "dark"] {
            UserDefaults.standard.set(scheme, forKey: "appearance")
            model.applyTheme()
            for name in ["short", "long"] {
                let p = model.projects.first { $0.name == name }!
                model.select(sessionID: model.sessions(of: p).first?.id ?? { model.newSession(in: p); return model.sessions(of: p).first!.id }())
                model.panelTab = .files
                model.findQuery = ""
                await SelfTest.pause(2)
                Screenshots.compositedSnapshot("\(dir)/\(prefix)-\(name)-\(scheme).png")
                Screenshots.snapshot("\(dir)/\(prefix)-view-\(name)-\(scheme).png")
                if name == "long" {
                    model.focusFind(); model.findQuery = "sess"
                    await SelfTest.pause(1.5)
                    Screenshots.compositedSnapshot("\(dir)/\(prefix)-find-\(scheme).png")
                    Screenshots.snapshot("\(dir)/\(prefix)-view-find-\(scheme).png")
                    model.findQuery = ""
                    model.panelTab = .context
                    await SelfTest.pause(1.5)
                    Screenshots.compositedSnapshot("\(dir)/\(prefix)-context-\(scheme).png")
                    Screenshots.snapshot("\(dir)/\(prefix)-view-context-\(scheme).png")
                }
            }
        }
        UserDefaults.standard.set("light", forKey: "appearance")
    }
}
