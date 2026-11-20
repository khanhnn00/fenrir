import AppKit
import Foundation

/// `FENRIR_SELFTEST=t029`: forwards a throwaway http server on a real host (`FENRIR_MACHINE_HOST`) through the
/// Ports tab model, curls it locally, stops the forward and removes the listener (tmux session `fenrir-t029-*`).
/// Needs FENRIR_SHOTS_DIR for the render of the Ports tab.
@MainActor
enum ForwardSelfTest {
    private static let env = ProcessInfo.processInfo.environment
    private static let port: UInt16 = 18929

    @discardableResult
    private static func run(_ exe: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try? p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static func remote(_ host: String, _ cmd: String) -> String {
        run("/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--", host, cmd])
    }

    private static func curl() -> String {
        run("/usr/bin/curl", ["-s", "-o", "/dev/null", "-m", "5", "-w", "%{http_code}", "http://127.0.0.1:\(port)/"])
    }

    private static func wait(_ what: String, _ ok: () async -> Bool) async -> Bool {
        for _ in 0..<60 { if await ok() { return true }; await SelfTest.pause(0.5) }
        SelfTest.log("timeout waiting for \(what)")
        return false
    }

    static func run(_ model: AppModel) async {
        guard let host = env["FENRIR_MACHINE_HOST"] else { SelfTest.log("FENRIR_MACHINE_HOST is required"); return }
        let dir = env["FENRIR_SHOTS_DIR"] ?? NSTemporaryDirectory() + "fenrir-shots"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let session = "fenrir-t029-\(Int(Date().timeIntervalSince1970))"
        defer { _ = remote(host, "tmux kill-session -t \(session) 2>/dev/null; true") }
        do {
            try model.addMachine(name: "", host: host)
            let home = try model.core.testMachine(host: host)
            model.add(name: "ports", path: home, host: host)
            model.showPanel = true
            model.panelTab = .ports
        } catch { SelfTest.log("setup failed: \(error)"); return }
        let server = "python3 -m http.server \(port) --bind 127.0.0.1"
        SelfTest.log("listener: \(remote(host, "tmux new-session -d -s \(session) '\(server)' && echo started"))")
        let pm = PortsModel(core: model.core, host: host)
        var seen = false
        _ = await wait("detect \(port)") { await pm.refresh(detect: true); seen = pm.detected.contains { $0.port == port }; return seen }
        SelfTest.log("PASS detected \(port) on host: \(seen) process=\(pm.process(forRemote: port))")
        pm.add(remote: port, local: nil)
        SelfTest.log("add error: \(pm.error ?? "none")")
        let active = await wait("active") { await pm.refresh(detect: false); return pm.forwards.first?.status == .active }
        SelfTest.log("PASS forward active: \(active) \(pm.forwards)")
        SelfTest.log("curl through forward: \(curl())")
        pm.add(remote: port, local: nil)
        SelfTest.log("live=\(model.core.forwardList(host: host))"); SelfTest.log("PASS second add rejected: \(pm.error ?? "none")")
        pm.add(remote: 18930, local: port)
        SelfTest.log("PASS busy local port message: \(pm.error ?? "none")")
        await SelfTest.pause(2)
        Screenshots.snapshot(dir + "/ports-tab.png")
        if let f = pm.forwards.first { pm.stop(f) }
        await SelfTest.pause(1)
        SelfTest.log("PASS stopped: forwards=\(pm.forwards.count) curl after stop: \(curl())")
        SelfTest.log("restore check: \(model.core.forwardList(host: host).count) live")
    }
}
