import AppKit
import SwiftUI

/// `FENRIR_SELFTEST=org`: an Organization project on an unresolvable host (no real machine is
/// contacted), to show the card, the reconnect loop and the remote panel states, plus offscreen
/// renders of the Organization add-project sheet and Settings.
@MainActor
enum OrgSelfTest {
    static func run(_ model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        let dir = env["FENRIR_SHOTS_DIR"] ?? NSTemporaryDirectory() + "fenrir-shots"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let repo = env["FENRIR_REPO"] ?? NSHomeDirectory()
        model.add(name: "fenrir", path: repo, host: nil)
        model.add(name: "company-api", path: "/srv/company-api", host: "fenrir-selftest.invalid")
        let org = model.projects.first { $0.name == "company-api" }!
        let item = model.sessions(of: org).first!
        for t in 1...12 {
            await SelfTest.pause(1)
            SelfTest.log("t=\(t)s state=\(item.state.label) alive=\(model.core.sessionAlive(id: item.id)) message=\(item.lastMessage ?? "-")")
        }
        model.panelTab = .files
        await SelfTest.pause(2)
        Screenshots.snapshot(dir + "/org-card-and-files.png")
        SelfTest.log("terminal tail: \(SelfTest.dump(model, item.id).split(separator: "\n").suffix(6).joined(separator: " | "))")
        Screenshots.render(AddProjectSheet(host: "dev-ec2", path: "/home/ubuntu/company-api", name: "company-api")
            .environmentObject(model), size: CGSize(width: 460, height: 330), to: dir + "/add-project-organization.png")
        Screenshots.render(SettingsView(core: model.core, onTheme: {}).environmentObject(model),
                           size: CGSize(width: 520, height: 900), to: dir + "/settings.png")
    }
}

extension Screenshots {
    /// Renders a SwiftUI view in a throwaway window and writes it as PNG.
    static func render<V: View>(_ view: V, size: CGSize, to path: String) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -4000, y: 0))
        win.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { SelfTest.log("render failed"); return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        win.orderOut(nil)
        SelfTest.log("saved \(path)")
    }
}
