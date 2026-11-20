import AppKit
import Foundation

/// `FENRIR_SELFTEST=subagent`: a real claude session in a temp dir launches one background subagent;
/// logs the card state through Working, Agents running and Idle and writes a card screenshot at each.
/// Needs FENRIR_REPO, FENRIR_HOME and FENRIR_SHOTS_DIR.
@MainActor
enum SubagentSelfTest {
    static func run(_ model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        guard let repo = env["FENRIR_REPO"], let home = env["FENRIR_HOME"] else { SelfTest.log("FENRIR_REPO and FENRIR_HOME required"); return }
        let dir = env["FENRIR_SHOTS_DIR"] ?? NSTemporaryDirectory() + "fenrir-shots"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let settings = home + "/hook-settings.json"
        let cmd = "node \(repo)/scripts/fenrir-hook.cjs"
        let events = ["UserPromptSubmit", "Stop", "Notification", "SubagentStart", "SubagentStop"]
        let hooks = events.map { "\"\($0)\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"\(cmd)\"}]}]" }
        try? "{\"hooks\":{\(hooks.joined(separator: ","))}}".write(toFile: settings, atomically: true, encoding: .utf8)
        // claude refuses untrusted folders, so FENRIR_CLAUDE_DIR names a trusted one.
        model.add(name: "subagent-probe", path: env["FENRIR_CLAUDE_DIR"] ?? SelfTest.tempDir("fenrir-subagent-probe"), host: nil)
        let id = model.selectedSessionID!
        let item = model.selectedSession!
        model.select(sessionID: id)
        await SelfTest.pause(3)
        SelfTest.type(model, id, "claude --settings \(settings)\n")
        await SelfTest.pause(10)
        SelfTest.type(model, id, "\r") // accepts the folder trust prompt when it shows
        await SelfTest.pause(4)
        SelfTest.type(model, id, "Launch exactly one background subagent (Agent tool, run_in_background true, subagent_type general-purpose, description 'sleep probe') whose only job is to run `sleep 45` in bash and then reply DONE. After launching it, reply with just OK and stop.")
        await SelfTest.pause(1.5)
        SelfTest.type(model, id, "\r")
        var last = ""
        var shot = Set<AgentState>()
        var sawAgents = false
        for _ in 0..<480 {
            await SelfTest.pause(0.5)
            let line = "state=\(item.state.label) unread=\(item.unread) msg=\(item.lastMessage ?? "-")"
            if line != last {
                last = line
                SelfTest.log(line)
                if item.state == .agentsRunning { sawAgents = true }
                if !shot.contains(item.state), item.state != .exited {
                    shot.insert(item.state)
                    Screenshots.snapshot("\(dir)/subagent-\(item.state.label.lowercased().replacingOccurrences(of: " ", with: "-")).png")
                }
            }
            if sawAgents && item.state == .idle { break }
        }
        SelfTest.log("sawAgentsRunning=\(sawAgents) final=\(item.state.label)")
        SelfTest.log("--- terminal ---\n\(SelfTest.dump(model, id).suffix(1200))")
        SelfTest.type(model, id, "\u{3}\u{3}")
    }
}
