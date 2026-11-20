import AppKit
import SwiftUI
import Foundation

/// `FENRIR_SELFTEST=layout`: sidebar open and closed, a second tab, and Files with Find active.
/// Needs FENRIR_REPO and FENRIR_SHOTS_DIR; the query comes from FENRIR_FIND (default `sess`).
@MainActor
enum LayoutSelfTest {
    static func run(_ model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        let dir = env["FENRIR_SHOTS_DIR"] ?? NSTemporaryDirectory() + "fenrir-shots"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let repo = env["FENRIR_REPO"] ?? NSHomeDirectory()
        model.showSidebar = true
        model.showPanel = true
        model.add(name: "fenrir", path: repo, host: nil)
        model.add(name: "gtm", path: (repo as NSString).deletingLastPathComponent, host: nil)
        await SelfTest.pause(2)
        let fenrir = model.projects.first { $0.name == "fenrir" }!
        model.newSession(in: fenrir)
        model.newTab()
        if let local = model.machines.first(where: { $0.host == nil }) { model.bind(tab: model.activeTabID, to: local) }
        model.activate(tab: model.tabs[0].id)
        model.select(sessionID: model.sessions(of: fenrir).first!.id)
        await SelfTest.pause(2)
        SelfTest.type(model, model.selectedSessionID!, "ls\n")
        await SelfTest.pause(1)
        Screenshots.snapshot(dir + "/layout-sidebar-open.png")
        for (label, w) in [("narrow", CGFloat(260)), ("wide", CGFloat(420))] {
            model.sidebarWidth = w
            await SelfTest.pause(1)
            Screenshots.snapshot(dir + "/layout-sidebar-\(label).png")
            measure(label, width: w)
        }
        model.sidebarWidth = 264
        model.showSidebar = false
        await SelfTest.pause(1)
        Screenshots.snapshot(dir + "/layout-sidebar-closed.png")
        model.showSidebar = true
        await SelfTest.pause(1)
        await addMachineWithCoder(model, dir: dir)
        model.panelTab = .files
        model.focusFind()
        model.findQuery = env["FENRIR_FIND"] ?? "sess"
        await SelfTest.pause(1.5)
        Screenshots.snapshot(dir + "/layout-files-find.png")
        SelfTest.log("find results shown for '\(model.findQuery)'")
        model.findQuery = ""
        model.goHome()
        await SelfTest.pause(1)
        Screenshots.snapshot(dir + "/layout-landing.png")
    }

    /// Strongest vertical edge near the sidebar width on a row inside the top bar and on a row inside the sidebar, in points.
    private static func measure(_ label: String, width: CGFloat) {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }), let v = w.contentView?.superview,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / v.bounds.width
        func edge(atY y: CGFloat) -> CGFloat {
            var best: (CGFloat, CGFloat) = (0, -1)
            let py = Int(y * scale)
            for px in Int((width - 12) * scale)...Int((width + 12) * scale) {
                guard let a = rep.colorAt(x: px - 1, y: py)?.usingColorSpace(.deviceRGB), let b = rep.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB) else { continue }
                let d = abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
                if d > best.1 { best = (CGFloat(px) / scale, d) }
            }
            return best.0
        }
        let bar = edge(atY: Space.bar / 2), side = edge(atY: Space.bar + 3)
        SelfTest.log("align \(label): sidebarWidth=\(width) bar divider x=\(bar) sidebar edge x=\(side) equal=\(bar == side)")
    }

    /// The real Add Machine sheet in a window, given time to load `coder list`.
    private static func addMachineWithCoder(_ model: AppModel, dir: String) async {
        let size = CGSize(width: 460, height: 460)
        let host = NSHostingView(rootView: AddMachineSheet().environmentObject(model).frame(width: size.width).background(Color(nsColor: .windowBackgroundColor)))
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -4000, y: 0))
        win.orderFront(nil)
        await SelfTest.pause(4)
        host.layoutSubtreeIfNeeded()
        let fit = host.fittingSize
        win.setContentSize(CGSize(width: size.width, height: fit.height))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/add-machine-coder.png"))
        win.orderOut(nil)
        SelfTest.log("saved add-machine-coder.png")
    }
}
