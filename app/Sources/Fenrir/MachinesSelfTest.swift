import AppKit
import Foundation
import SwiftUI

/// `FENRIR_SELFTEST=machines-seed` / `machines-check`: Local plus one real ssh host (`FENRIR_MACHINE_HOST`,
/// path `FENRIR_MACHINE_PATH`) in two tabs. Seed adds the machine, opens a tmux session on it and waits to
/// be killed; check relaunches with the same FENRIR_HOME, logs the restored tabs, then removes the
/// throwaway tmux session it created. Needs FENRIR_REPO and FENRIR_SHOTS_DIR.
@MainActor
enum MachinesSelfTest {
    private static let env = ProcessInfo.processInfo.environment
    private static var host: String { env["FENRIR_MACHINE_HOST"] ?? "example-host" }
    private static let project = "livecheck"

    private static func tabs(_ model: AppModel) -> String {
        model.tabs.map { t in
            let m = model.machine(of: t)?.name ?? "landing"
            return "\(m)\(t.id == model.activeTabID ? "*" : "")[session=\(t.selectedSessionID.map(String.init) ?? "-")]"
        }.joined(separator: " ")
    }

    /// Runs one ssh command on the host and returns its output.
    private static func remote(_ cmd: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--", host, cmd]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try? p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func seed(_ model: AppModel) async {
        let dir = env["FENRIR_SHOTS_DIR"] ?? NSTemporaryDirectory() + "fenrir-shots"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        model.add(name: "fenrir", path: env["FENRIR_REPO"] ?? NSHomeDirectory(), host: nil)
        await SelfTest.pause(1.5)
        do {
            let home = try model.core.testMachine(host: host)
            SelfTest.log("machine \(host) reachable, home=\(home)")
            try model.addMachine(name: "", host: host)
        } catch { SelfTest.log("add machine failed: \(error)"); return }
        SelfTest.log("machines: \(model.machines.map { "\($0.name)/\($0.host ?? "local")" })")
        model.newTab()
        await SelfTest.pause(1)
        Screenshots.snapshot(dir + "/landing-zone.png")
        Screenshots.render(AddMachineSheet(host: "dev-box", name: "Dev box").environmentObject(model),
                           size: CGSize(width: 460, height: 300), to: dir + "/add-machine.png")
        guard let machine = model.machines.first(where: { $0.host == host }) else { return }
        model.bind(tab: model.activeTabID, to: machine)
        model.add(name: project, path: env["FENRIR_MACHINE_PATH"] ?? "/home/ubuntu", host: host)
        let id = model.selectedSessionID!
        await SelfTest.pause(8)
        SelfTest.type(model, id, "echo live-marker-$((6*7)); pwd\n")
        await SelfTest.pause(2)
        SelfTest.log("tabs: \(tabs(model))")
        SelfTest.log("remote terminal: \(SelfTest.dump(model, id).split(separator: "\n").suffix(6).joined(separator: " | "))")
        SelfTest.log("remote tmux: \(remote("tmux ls | grep fenrir-").split(separator: "\n").joined(separator: " | "))")
        Screenshots.snapshot(dir + "/two-tabs-remote.png")
        model.switchTab(by: -1)
        await SelfTest.pause(1)
        Screenshots.snapshot(dir + "/two-tabs-local.png")
        model.switchTab(by: 1)
        await SelfTest.pause(7)
        SelfTest.log("seed: saved, waiting to be killed; tabs: \(tabs(model))")
        await SelfTest.pause(300)
    }

    static func check(_ model: AppModel) async {
        await SelfTest.pause(15)
        SelfTest.log("check: \(model.sessions.count) sessions; tabs: \(tabs(model))")
        for s in model.sessions {
            let name = model.projects.first { $0.id == s.projectID }?.name ?? "?"
            SelfTest.log("check: session \(s.id) project=\(name) host=\(s.host ?? "local") state=\(s.state.label)")
        }
        if let s = model.selectedSession {
            SelfTest.log("check: selected screen: \(SelfTest.dump(model, s.id).split(separator: "\n").suffix(6).joined(separator: " | "))")
        }
        if let dir = env["FENRIR_SHOTS_DIR"] { Screenshots.snapshot(dir + "/restored-tabs.png") }
        let names = remote("tmux ls -F '#{session_name}' | grep '^fenrir-\(project)-'").split(separator: "\n")
        SelfTest.log("cleanup: killing tmux sessions \(names)")
        for n in names { _ = remote("tmux kill-session -t '\(n)'") }
        SelfTest.log("remote tmux after cleanup: [\(remote("tmux ls | grep fenrir-").split(separator: "\n").joined(separator: " | "))]")
    }
}
