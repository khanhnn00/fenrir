import AppKit
import SwiftUI
@preconcurrency import SwiftTerm

enum AgentState {
    case working, idle, needsInput, exited
    /// The main turn stopped but subagents are still running.
    case agentsRunning
    /// Organization only: the ssh link dropped; tmux keeps the agent running on the host.
    case reconnecting

    var label: String {
        switch self {
        case .working: return "Working"
        case .idle: return "Idle"
        case .needsInput: return "Needs input"
        case .exited: return "Ended"
        case .agentsRunning: return "Agents running"
        case .reconnecting: return "Reconnecting"
        }
    }
    var color: SwiftUI.Color {
        switch self {
        case .working: return Theme.working
        case .idle: return Theme.idle
        case .needsInput: return Theme.needsInput
        case .exited: return Theme.exited
        case .agentsRunning: return Theme.agents
        case .reconnecting: return Theme.needsInput
        }
    }
}

/// One terminal tab of a project, with the agent state shown in the nav.
@MainActor
final class SessionItem: ObservableObject, Identifiable {
    let id: Int64
    let projectID: Int64
    let ordinal: Int
    /// SSH alias for Organization sessions, `nil` for local ones.
    let host: String?
    let term: TerminalSession
    @Published var state: AgentState = .idle
    @Published var unread = 0
    @Published var lastActivity = Date()
    @Published var lastMessage: String?
    /// Claude conversation name from the hook transcript, else the first prompt seen; `nil` until a hook fires.
    @Published var title: String?
    /// Name the user typed that Claude has no conversation to carry yet; kept until the transcript takes it.
    var pendingName: String?
    /// True once any hook event arrived; before that the card cannot know if an agent runs.
    @Published var heardFromHook = false
    /// When the user last opened this session; the project card reopens the most recent one.
    var lastViewed: Date?
    /// Subagents running now, longest-running first.
    @Published var agents: [AgentInfo] = []
    /// State to go back to once the ssh link is up again.
    var stateBeforeDrop: AgentState = .idle
    /// Main turn plus running subagents, fed by hook events.
    let tracker = AgentTracker()

    init(term: TerminalSession, projectID: Int64, ordinal: Int, host: String?) {
        self.id = term.id
        self.term = term
        self.projectID = projectID
        self.ordinal = ordinal
        self.host = host
    }

    var claudeSession: String?
    /// Remote only: tmux session the user attached in this terminal, polled from the host.
    var tmuxSession: String?
    /// Set while a Stop waits to be confirmed; a newer event for the session replaces it.
    var settleToken: UUID?
    /// Remote: claude's full-screen view was showing when the ssh link dropped.
    var claudeOnScreenAtDrop = false
    var claudeCwd: String?
    private var resumeClaude = false
    private var scrollback = ""

    /// What the nav row calls this session.
    var displayTitle: String { title ?? "Terminal \(ordinal)" }

    func touch(_ date: Date = Date()) { lastActivity = max(lastActivity, date) }

    /// Plain-text copy of the shell's scrollback (the normal buffer, also while a full-screen app is showing).
    func snapshot() -> SavedSession {
        let view = term.view
        if term.takeDirty() {
            let lines = String(decoding: view.getTerminal().getBufferAsData(kind: .normal), as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: false)
            var kept = lines.suffix(5000)
            while kept.last?.isEmpty == true { kept.removeLast() }
            scrollback = kept.joined(separator: "\n")
        }
        // Inside tmux the agent keeps running on the host and is attached again; otherwise claude is resumed.
        resumeClaude = tmuxSession == nil && claudeSession != nil && view.isAlternateScreen
        return SavedSession(projectID: projectID, ordinal: ordinal, claudeSession: claudeSession, claudeCwd: claudeCwd,
                            resumeClaude: resumeClaude, tmux: tmuxSession, scrollback: scrollback, title: title)
    }
}

/// SwiftTerm view bridged to a Rust PTY session.
final class TerminalSession: NSObject, TerminalViewDelegate, OutputListener, @unchecked Sendable {
    let view: TerminalView
    private let core: FenrirCore
    private let projectID: Int64
    private let ordinal: Int
    private let remote: Bool
    private(set) var id: Int64 = 0
    var activityHandler: (@MainActor () -> Void)?
    var exitHandler: (@MainActor () -> Void)?
    /// Remote only: called with the attempt number while the link is down (0 once it is back).
    var linkHandler: (@MainActor (Int) -> Void)?
    /// Set when the user closes the card, so the dying ssh is not reconnected.
    var closed = false
    private var attempt = 0
    private var lastPing = Date.distantPast
    /// SGR mouse reports sent to the app (wheel forwarding), for selftests.
    var wheelReports = 0
    /// Selftest probes: bytes arriving from the PTY and bytes sent to it.
    var rawTap: ((Data) -> Void)?
    var sendTap: ((ArraySlice<UInt8>) -> Void)?
    private var outputSinceSnapshot = true
    func takeDirty() -> Bool { defer { outputSinceSnapshot = false }; return outputSinceSnapshot }

    init(core: FenrirCore, projectID: Int64, ordinal: Int, remote: Bool) {
        self.core = core
        self.projectID = projectID
        self.ordinal = ordinal
        self.remote = remote
        view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        super.init()
        view.terminalDelegate = self
        let menu = NSMenu()
        for (title, action) in [("Copy", #selector(NSText.copy(_:))), ("Paste", #selector(NSText.paste(_:))), ("Select All", #selector(NSText.selectAll(_:)))] {
            menu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: ""))
        }
        view.menu = menu
    }

    func start() throws {
        let t = view.getTerminal()
        id = try core.newSession(projectId: projectID, ordinal: UInt32(ordinal), cols: UInt16(clamping: max(t.cols, 1)),
                                 rows: UInt16(clamping: max(t.rows, 1)), listener: self)
        // Restored sessions start before their view has its real size; push it once the window is laid out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in syncSize() }
    }

    /// Sends the view's current grid to the PTY, nudging one column so ssh and tmux always see a change.
    func syncSize() {
        guard id != 0, !closed else { return }
        let t = view.getTerminal()
        let cols = UInt16(clamping: max(t.cols, 2)), rows = UInt16(clamping: max(t.rows, 1))
        SizeLog.write("syncSize id=\(id) grid=\(t.cols)x\(t.rows) frame=\(view.frame.size) window=\(view.window != nil) superview=\(view.superview?.frame.size ?? .zero)")
        try? core.resizeSession(id: id, cols: cols - 1, rows: rows)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in try? core.resizeSession(id: id, cols: cols, rows: rows) }
    }

    // MARK: OutputListener (Rust thread)
    func onOutput(data: Data) {
        DispatchQueue.main.async { [self] in
            outputSinceSnapshot = true
            rawTap?(data)
            view.feed(byteArray: ArraySlice([UInt8](data)))
            if Date().timeIntervalSince(lastPing) > 5 {
                lastPing = Date()
                MainActor.assumeIsolated { activityHandler?() }
            }
        }
    }

    func onExit(code: Int32) {
        DispatchQueue.main.async { [self] in
            // ssh exits 255 when the connection fails or drops; tmux on the host still holds the session.
            if remote && code == 255 && !closed { return linkDropped() }
            view.feed(text: "\r\n[session ended]\r\n")
            MainActor.assumeIsolated { exitHandler?() }
        }
    }

    // MARK: reconnect (Organization)
    static func retryDelay(attempt: Int) -> TimeInterval { min(Double(attempt) * 3, 30) }

    private func linkDropped() {
        attempt += 1
        let delay = Self.retryDelay(attempt: attempt)
        view.feed(text: "\r\n\u{1b}[2m[connection lost; reconnecting in \(Int(delay))s, attempt \(attempt)]\u{1b}[0m\r\n")
        MainActor.assumeIsolated { linkHandler?(attempt) }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            guard !closed else { return }
            let t = view.getTerminal()
            do {
                try core.reconnectSession(id: id, cols: UInt16(clamping: max(t.cols, 1)), rows: UInt16(clamping: max(t.rows, 1)))
            } catch { return linkDropped() }
            // An ssh that is still running after a few seconds has connected.
            let mine = attempt
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [self] in
                guard !closed, attempt == mine, core.sessionAlive(id: id) else { return }
                attempt = 0
                MainActor.assumeIsolated { linkHandler?(0) }
            }
        }
    }

    // MARK: TerminalViewDelegate
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if data.count > 4, data.starts(with: [0x1b, 0x5b, 0x3c]) { wheelReports += 1 }
        sendTap?(data)
        try? core.writeSession(id: id, data: Data(data))
        // Typing returns the viewport to the live screen, as other terminals do.
        if view.canScroll, view.scrollPosition < 1 { view.scrollDown(lines: Int(UInt16.max)) }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        SizeLog.write("sizeChanged id=\(id) grid=\(newCols)x\(newRows) frame=\(view.frame.size)")
        try? core.resizeSession(id: id, cols: UInt16(clamping: max(newCols, 1)), rows: UInt16(clamping: max(newRows, 1)))
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func clipboardCopy(source: TerminalView, content: Data) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(decoding: content, as: UTF8.self), forType: .string)
    }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
    func bell(source: TerminalView) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}

/// Size diagnostics in ~/.fenrir/size.log (temporary, for the remote size bug).
enum SizeLog {
    static func write(_ s: String) {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.fenrir/size.log")
        let line = "\(Date()) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }
}
