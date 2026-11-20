import Foundation

/// One session as written to `$FENRIR_HOME/sessions.json`.
struct SavedSession: Codable {
    var projectID: Int64
    var ordinal: Int
    /// Last Claude conversation seen in this session through the hooks, and the cwd it ran in.
    var claudeSession: String?
    var claudeCwd: String?
    /// True when the claude TUI was on screen at the last snapshot, so relaunch resumes it.
    var resumeClaude: Bool
    /// Remote only: the tmux session the user had attached in this terminal; relaunch attaches it again.
    var tmux: String?
    var scrollback: String
    /// Name shown on the row; absent in files written before sessions could be renamed.
    var title: String?
}

/// One window tab: the machine it is bound to (`host` nil = Local) or the landing zone, and the
/// index into `sessions` of its selected session.
struct SavedTab: Codable {
    var host: String?
    var landing: Bool
    var selected: Int?
}

struct SavedState: Codable {
    var sessions: [SavedSession]
    var selected: Int?
    /// Absent in files written before tabs existed.
    var tabs: [SavedTab]?
    var activeTab: Int?
}

/// Atomic JSON file holding every open session, rewritten periodically and on quit.
struct SessionStore {
    let url: URL

    init(dataDir: String) { url = URL(fileURLWithPath: dataDir).appendingPathComponent("sessions.json") }

    func load() -> SavedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedState.self, from: data)
    }

    func save(_ state: SavedState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Command typed into the restored shell to bring the Claude conversation back.
    static func attachCommand(tmux: String) -> String {
        "tmux attach -t '" + tmux.replacingOccurrences(of: "'", with: "'\\''") + "'\n"
    }

    static func resumeCommand(session: String, cwd: String?) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let cd = cwd.map { "cd \(q($0)) && " } ?? ""
        return "\(cd)claude --resume \(q(session))\n"
    }
}
