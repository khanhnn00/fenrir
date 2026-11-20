import AppKit
import Foundation
import SwiftUI

enum PanelTab: String, CaseIterable { case files = "Files", context = "Context", ports = "Ports" }

enum NavEntry: Identifiable {
    case session(SessionItem, Project)
    case idle(Project)

    var id: String {
        switch self {
        case .session(let s, _): return "s\(s.id)"
        case .idle(let p): return "p\(p.id)"
        }
    }
}

/// One tab of the window: a machine (nil while it still shows the landing zone) and what is open on it.
struct TabState: Identifiable {
    var id = UUID()
    var machineID: Int64?
    var selectedSessionID: Int64?
    var focusedProjectID: Int64?
    var showSftp = false
    var panelTab = PanelTab.files
    /// Files opened in this tab, in order, and the one shown instead of the terminal (nil = terminal).
    var files: [UUID] = []
    var shownFile: UUID?
}

enum MachineStatus: Equatable {
    case checking
    case online
    case offline(String)
}

@MainActor
final class AppModel: ObservableObject {
    let core: FenrirCore
    let sftp: SftpModel
    @Published var projects: [Project] = []
    @Published var machines: [Machine] = []
    @Published var machineStatus: [Int64: MachineStatus] = [:]
    private var probedAt: [Int64: Date] = [:]
    @Published var sessions: [SessionItem] = []
    @Published var docs: [FileDoc] = []
    @Published var tabs: [TabState]
    @Published var activeTabID: UUID
    @Published var showQuickSwitcher = false
    @Published var showAddProject = false
    @Published var showAddMachine = false
    @Published var showSidebar = UserDefaults.standard.object(forKey: "showSidebar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showSidebar, forKey: "showSidebar") }
    }
    /// Width of the left column; the top bar's leading region uses the same value so the dividers line up.
    @Published var sidebarWidth: CGFloat = {
        let w = UserDefaults.standard.double(forKey: "sidebarWidth")
        return w == 0 ? 264 : min(max(CGFloat(w), AppModel.sidebarRange.lowerBound), AppModel.sidebarRange.upperBound)
    }() {
        didSet { UserDefaults.standard.set(Double(sidebarWidth), forKey: "sidebarWidth") }
    }
    static let sidebarRange: ClosedRange<CGFloat> = 250...480
    @Published var showPanel = UserDefaults.standard.object(forKey: "showPanel") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showPanel, forKey: "showPanel") }
    }
    /// Bumped by ⌘P so the Files tab focuses its Find field.
    @Published var findFocusToken = 0
    @Published var findQuery = ""
    @Published var errorMessage: String?
    private var poller: Timer?
    private var saver: Timer?
    private let store: SessionStore

    init() {
        let first = TabState()
        tabs = [first]
        activeTabID = first.id
        let dir = ProcessInfo.processInfo.environment["FENRIR_HOME"] ?? (NSHomeDirectory() + "/.fenrir")
        store = SessionStore(dataDir: dir)
        do {
            core = try FenrirCore(dataDir: dir)
            projects = try core.listProjects()
            machines = try core.listMachines()
        } catch {
            fatalError("Cannot open Fenrir data dir \(dir): \(error)")
        }
        sftp = SftpModel(core: core)
        Notifier.shared.onSelect = { [weak self] id in self?.select(sessionID: id) }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.markSelectedSeen() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSessions(); self?.core.forwardStopAll() }
        }
    }

    /// ⌘P: open the right panel on Files and focus Find.
    func focusFind() {
        guard activeProject != nil else { return }
        showPanel = true
        panelTab = .files
        findFocusToken += 1
    }

    func startPolling() {
        guard poller == nil else { return }
        poller = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollEvents() }
        }
    }

    // MARK: tabs
    var activeIndex: Int { tabs.firstIndex { $0.id == activeTabID } ?? 0 }
    var activeTab: TabState { tabs[activeIndex] }
    var activeMachine: Machine? { machines.first { $0.id == activeTab.machineID } }

    var selectedSessionID: Int64? {
        get { activeTab.selectedSessionID }
        set { tabs[activeIndex].selectedSessionID = newValue }
    }
    var focusedProjectID: Int64? {
        get { activeTab.focusedProjectID }
        set { tabs[activeIndex].focusedProjectID = newValue }
    }
    /// The tab shows the file transfer view (this Mac | a host) in place of the terminal.
    var showSftp: Bool {
        get { activeTab.showSftp }
        set { tabs[activeIndex].showSftp = newValue }
    }
    var panelTab: PanelTab {
        get { activeTab.panelTab }
        set { tabs[activeIndex].panelTab = newValue }
    }

    func machine(of project: Project) -> Machine? { machines.first { $0.host == project.host } }
    func machine(of tab: TabState) -> Machine? { machines.first { $0.id == tab.machineID } }

    /// Opens the transfer view in the active tab (binding a landing-zone tab to `machine` first); a remote
    /// `machine` becomes the host of the right pane.
    func openSftp(for machine: Machine? = nil) {
        let m = machine ?? activeMachine
        if activeMachine == nil, let b = m ?? machines.first { bind(tab: activeTabID, to: b) }
        if let host = m?.host { sftp.choose(host: host) }
        showSftp = true
    }

    /// Home: the active tab goes back to the landing zone; its sessions keep running.
    func goHome() {
        guard confirmDiscardFiles(inTabAt: activeIndex) else { return }
        tabs[activeIndex] = TabState(id: activeTabID)
    }

    /// Hands keyboard focus back to the selected terminal.
    func focusTerminal() {
        DispatchQueue.main.async { [self] in if let v = selectedSession?.term.view { v.window?.makeFirstResponder(v) } }
    }

    /// ⌘N: a tab showing the landing zone.
    func newTab() {
        let t = TabState()
        tabs.append(t)
        activeTabID = t.id
    }

    /// ⇧⌘W: sessions keep running; the last tab turns back into the landing zone.
    func closeTab(_ id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        guard confirmDiscardFiles(inTabAt: i) else { return }
        if tabs.count == 1 { tabs[0] = TabState(); activeTabID = tabs[0].id; return }
        tabs.remove(at: i)
        if activeTabID == id { activeTabID = tabs[min(i, tabs.count - 1)].id }
        markSelectedSeen()
    }

    func switchTab(by step: Int) {
        let i = (activeIndex + step + tabs.count) % tabs.count
        activeTabID = tabs[i].id
        markSelectedSeen()
    }

    func activate(tab id: UUID) {
        activeTabID = id
        markSelectedSeen()
    }

    /// Choosing a machine on the landing zone binds the tab to it.
    func bind(tab id: UUID, to machine: Machine) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[i].machineID = machine.id
        tabs[i].selectedSessionID = nil
        tabs[i].focusedProjectID = nil
        tabs[i].showSftp = false
        if machine.host != nil { probe(machine) }
    }

    /// Index of the tab to work in for `machine`: the active one if it is on that machine, else the
    /// active one when it is still empty, else an existing tab for it, else a new tab.
    private func tabIndex(for machine: Machine) -> Int {
        if activeTab.machineID == machine.id { return activeIndex }
        if activeTab.machineID == nil { tabs[activeIndex].machineID = machine.id; return activeIndex }
        if let i = tabs.firstIndex(where: { $0.machineID == machine.id }) { return i }
        var t = TabState()
        t.machineID = machine.id
        tabs.append(t)
        return tabs.count - 1
    }

    // MARK: machines
    func reloadMachines() {
        machines = (try? core.listMachines()) ?? machines
        projects = (try? core.listProjects()) ?? projects
    }

    func projects(on machine: Machine) -> [Project] { projects.filter { $0.host == machine.host } }
    func sessions(on machine: Machine) -> [SessionItem] { sessions.filter { $0.host == machine.host } }
    func unread(on machine: Machine) -> Int { sessions(on: machine).reduce(0) { $0 + $1.unread } }

    func addMachine(name: String, host: String) throws {
        let m = try core.addMachine(name: name, host: host)
        reloadMachines()
        machineStatus[m.id] = .online
        probedAt[m.id] = Date()
        // Wire the agent-status hooks on the new host so its cards show running and done states.
        let core = self.core
        Task.detached {
            do {
                let report = try core.installRemoteHooks(host: host)
                await MainActor.run { self.log("hooks on \(host): \(report)") }
            } catch {
                await MainActor.run { self.errorMessage = "Could not install Fenrir hooks on \(host): \(error)" }
            }
        }
    }

    func rename(_ machine: Machine, to name: String) {
        do { try core.renameMachine(id: machine.id, name: name); reloadMachines() } catch { errorMessage = "\(error)" }
    }

    func remove(_ machine: Machine) {
        guard machine.host != nil else { return }
        for s in sessions(on: machine) { close(s) }
        do { try core.removeMachine(id: machine.id) } catch { errorMessage = "\(error)"; return }
        for i in tabs.indices where tabs[i].machineID == machine.id { tabs[i] = TabState(id: tabs[i].id) }
        reloadMachines()
        machineStatus[machine.id] = nil
    }

    /// Local is always on; a remote machine is checked with a non-interactive ssh and the result is
    /// reused for a minute.
    func probe(_ machine: Machine, force: Bool = false) {
        guard let host = machine.host else { return }
        if !force, let t = probedAt[machine.id], Date().timeIntervalSince(t) < 60 { return }
        probedAt[machine.id] = Date()
        machineStatus[machine.id] = .checking
        let core = self.core
        Task {
            let r: MachineStatus
            do { _ = try await Task.detached { try core.testMachine(host: host) }.value; r = .online }
            catch { r = .offline("\(error)") }
            machineStatus[machine.id] = r
        }
    }

    func probeAll() { for m in machines where m.host != nil { probe(m) } }

    /// Brings back the port forwards saved for every remote machine.
    func restoreForwards() { for case let h? in machines.map(\.host) { try? core.forwardRestore(host: h) } }

    // MARK: restore
    /// Recreates the sessions and tabs of the previous run (same cards, order, tab machines and
    /// selections), shows their scrollback and resumes the Claude conversation that was on screen.
    func restoreSessions() {
        defer { startSaving(); probeAll() }
        guard sessions.isEmpty, let saved = store.load() else { return }
        for s in saved.sessions {
            guard let project = projects.first(where: { $0.id == s.projectID }) else { continue }
            newSession(in: project, restoring: s)
        }
        restoreTabs(saved)
        log("restored \(sessions.count) sessions in \(tabs.count) tabs")
    }

    private func restoreTabs(_ saved: SavedState) {
        func session(at i: Int?) -> SessionItem? { i.flatMap { sessions.indices.contains($0) ? sessions[$0] : nil } }
        var restored: [TabState] = []
        for st in saved.tabs ?? [] {
            var t = TabState()
            if !st.landing, let m = machines.first(where: { $0.host == st.host }) {
                t.machineID = m.id
                if let s = session(at: st.selected), s.host == m.host {
                    t.selectedSessionID = s.id
                    t.focusedProjectID = s.projectID
                }
            }
            restored.append(t)
        }
        if restored.isEmpty, let s = session(at: saved.selected) ?? sessions.last, let m = machines.first(where: { $0.host == s.host }) {
            var t = TabState()
            t.machineID = m.id
            t.selectedSessionID = s.id
            t.focusedProjectID = s.projectID
            restored = [t]
        }
        guard !restored.isEmpty else { return }
        tabs = restored
        activeTabID = restored[min(max(saved.activeTab ?? 0, 0), restored.count - 1)].id
    }

    func saveSessions() {
        let tabStates = tabs.map { t -> SavedTab in
            let m = machine(of: t)
            return SavedTab(host: m?.host, landing: m == nil, selected: sessions.firstIndex { $0.id == t.selectedSessionID })
        }
        let saved = SavedState(sessions: sessions.map { $0.snapshot() }, selected: sessions.firstIndex { $0.id == selectedSessionID },
                               tabs: tabStates, activeTab: activeIndex)
        store.save(saved)
    }

    private func startSaving() {
        guard saver == nil else { return }
        saver = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSessions() }
        }
    }

    // MARK: derived
    var selectedSession: SessionItem? { sessions.first { $0.id == selectedSessionID } }
    var activeProjectID: Int64? { selectedSession?.projectID ?? focusedProjectID }
    var activeProject: Project? { projects.first { $0.id == activeProjectID } }
    var totalUnread: Int { sessions.reduce(0) { $0 + $1.unread } }

    func sessions(of project: Project) -> [SessionItem] { sessions.filter { $0.projectID == project.id } }

    /// Projects of a machine for the sidebar, one card each.
    func navProjects(_ machine: Machine?) -> [Project] { projects.filter { machine == nil || $0.host == machine?.host } }

    /// Projects with their sessions (or one idle entry) for a machine; `nil` lists every machine.
    func navEntries(_ machine: Machine?) -> [NavEntry] {
        projects.filter { machine == nil || $0.host == machine?.host }.flatMap { p -> [NavEntry] in
            let own = sessions(of: p)
            return own.isEmpty ? [.idle(p)] : own.map { .session($0, p) }
        }
    }

    // MARK: projects and sessions
    /// Adds a project to a machine (`host` nil = Local) and opens it in this tab.
    func add(name: String, path: String, host: String?) {
        do {
            let p = try core.addProject(name: name, path: path, host: host)
            reloadMachines()
            open(project: p)
        } catch { errorMessage = "\(error)" }
    }

    /// Display name only; the folder is untouched.
    func rename(_ project: Project, to name: String) {
        try? core.renameProject(id: project.id, name: name)
        projects = (try? core.listProjects()) ?? projects
    }

    /// Moves `id` to sit where `target` is among the machine's cards, and keeps the order.
    func moveProject(_ id: Int64, before target: Int64) {
        var ids = projects.map(\.id)
        guard id != target, let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target) else { return }
        ids.insert(ids.remove(at: from), at: to)
        try? core.reorderProjects(ids: ids)
        projects = (try? core.listProjects()) ?? projects
    }

    /// Row name; also the Claude conversation name, as `/rename` sets it, once there is a transcript to write.
    func rename(_ s: SessionItem, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        s.title = n
        s.pendingName = n
        guard let sid = s.claudeSession, let cwd = s.claudeCwd else { return }
        let core = self.core, host = s.host
        Task.detached {
            let wrote = (try? core.renameClaudeSession(host: host, cwd: cwd, claudeSession: sid, name: n)) ?? false
            if wrote { await MainActor.run { if s.pendingName == n { s.pendingName = nil } } }
        }
    }

    func remove(_ project: Project) {
        for s in sessions(of: project) { close(s) }
        try? core.removeProject(id: project.id)
        projects = (try? core.listProjects()) ?? projects
        for i in tabs.indices where tabs[i].focusedProjectID == project.id { tabs[i].focusedProjectID = nil }
    }

    /// Selects the project's most recent session, starting one when it has none.
    func open(project: Project) {
        if let m = machine(of: project) {
            let i = tabIndex(for: m)
            activeTabID = tabs[i].id
        }
        showSftp = false
        focusedProjectID = project.id
        let recent = sessions(of: project).max { ($0.lastViewed ?? .distantPast) < ($1.lastViewed ?? .distantPast) }
        if let s = recent { select(sessionID: s.id) } else { newSession(in: project) }
    }

    func newSession(in project: Project, restoring saved: SavedSession? = nil) {
        let ordinal = saved?.ordinal ?? (sessions(of: project).map(\.ordinal).max() ?? 0) + 1
        let remote = project.host != nil
        let term = TerminalSession(core: core, projectID: project.id, ordinal: ordinal, remote: remote)
        Theme.apply(to: term.view, dark: isDark)
        // Remote sessions are redrawn by tmux on re-attach, so there is nothing to replay.
        if !remote, let text = saved?.scrollback, !text.isEmpty {
            term.view.feed(text: text.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n\u{1b}[2m-- restored --\u{1b}[0m\r\n")
        }
        do { try term.start() } catch { errorMessage = "\(error)"; return }
        let item = SessionItem(term: term, projectID: project.id, ordinal: ordinal, host: project.host)
        item.claudeSession = saved?.claudeSession
        item.claudeCwd = saved?.claudeCwd
        item.tmuxSession = saved?.tmux
        item.title = saved?.title
        if let t = saved?.tmux {
            try? core.writeSession(id: item.id, data: Data(SessionStore.attachCommand(tmux: t).utf8))
        } else if let saved, saved.resumeClaude, let c = saved.claudeSession {
            try? core.writeSession(id: item.id, data: Data(SessionStore.resumeCommand(session: c, cwd: saved.claudeCwd).utf8))
        }
        term.activityHandler = { [weak item] in item?.touch() }
        term.linkHandler = { [weak item] attempt in
            guard let item, item.state != .exited else { return }
            if attempt > 0 {
                if item.state != .reconnecting {
                    item.stateBeforeDrop = item.state
                    item.claudeOnScreenAtDrop = item.term.view.isAlternateScreen
                }
                item.state = .reconnecting
                item.lastMessage = "Connection lost, retrying"
            } else if item.state == .reconnecting {
                // The new ssh is a fresh shell: go back into the user's tmux, or resume claude if it was on screen.
                if let t = item.tmuxSession {
                    try? self.core.writeSession(id: item.id, data: Data(SessionStore.attachCommand(tmux: t).utf8))
                } else if item.claudeOnScreenAtDrop, let c = item.claudeSession {
                    try? self.core.writeSession(id: item.id, data: Data(SessionStore.resumeCommand(session: c, cwd: item.claudeCwd).utf8))
                }
                item.state = item.stateBeforeDrop
                item.lastMessage = nil
                item.touch()
            }
        }
        term.exitHandler = { [weak item] in item?.state = .exited; item?.lastMessage = nil; item?.touch() }
        sessions.append(item)
        if saved == nil { select(sessionID: item.id) }
        log("session \(item.id) started for project \(project.id)")
    }

    /// Closes the session after a confirmation when Claude is still busy in it.
    func requestClose(_ s: SessionItem) {
        if s.state == .working || s.state == .agentsRunning {
            let alert = NSAlert()
            alert.messageText = "Close \(s.displayTitle)?"
            alert.informativeText = "Claude is still working in this session. Closing it ends the terminal."
            alert.addButton(withTitle: "Close Session")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        close(s)
    }

    /// Ends the session (remote: its tmux session too). Tabs showing it move to the next session of the
    /// project, else the previous one, else the project's empty state.
    func close(_ s: SessionItem) {
        let siblings = sessions.filter { $0.projectID == s.projectID }
        let at = siblings.firstIndex { $0.id == s.id } ?? 0
        let rest = siblings.filter { $0.id != s.id }
        let successor = rest.isEmpty ? nil : rest[min(at, rest.count - 1)]
        s.term.closed = true
        core.closeSession(id: s.id)
        sessions.removeAll { $0.id == s.id }
        saveSessions()
        for i in tabs.indices where tabs[i].selectedSessionID == s.id {
            tabs[i].selectedSessionID = successor?.id
            tabs[i].focusedProjectID = s.projectID
        }
        markSelectedSeen()
        focusTerminal()
    }

    /// Shows the session in the tab that already has it open, else in a tab of its machine.
    func select(sessionID: Int64) {
        guard let s = sessions.first(where: { $0.id == sessionID }),
              let project = projects.first(where: { $0.id == s.projectID }), let m = machine(of: project) else { return }
        let i: Int
        if activeTab.selectedSessionID == sessionID { i = activeIndex }
        else if let open = tabs.firstIndex(where: { $0.selectedSessionID == sessionID && $0.machineID == m.id }) { i = open }
        else { i = tabIndex(for: m) }
        activeTabID = tabs[i].id
        s.lastViewed = Date()
        // A hidden terminal may have missed its resize; resend the size once it is on screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { s.term.syncSize() }
        tabs[i].shownFile = nil
        tabs[i].showSftp = false
        tabs[i].selectedSessionID = sessionID
        tabs[i].focusedProjectID = s.projectID
        markSelectedSeen()
    }

    func markSelectedSeen() {
        guard let s = selectedSession, s.unread > 0 else { return }
        s.unread = 0
        NSApp.dockTile.badgeLabel = totalUnread > 0 ? "\(totalUnread)" : nil
    }

    /// ⌘1…⌘9: projects of the machine in this tab.
    func openProject(at index: Int) {
        guard let m = activeMachine else { return }
        let list = projects(on: m)
        if list.indices.contains(index) { open(project: list[index]) }
    }

    // MARK: theme
    var isDark: Bool {
        switch Appearance.stored {
        case .dark: return true
        case .light: return false
        case .system: return NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    func applyTheme() { for s in sessions { Theme.apply(to: s.term.view, dark: isDark) } }

    // MARK: hook events
    func pollEvents() {
        checkShownFile()
        for e in core.pollEvents() { handle(e) }
        // Subagents that went silent age out without any event.
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for s in sessions where s.state != .exited {
            if let u = s.tracker.tick(nowMs: now) { show(u, on: s, message: nil) }
        }
        pollAgentTranscripts(now: now)
        pollTmuxAttachments()
    }

    private var lastTmuxPoll = Date.distantPast

    /// Every 10 s asks each remote host which tmux session every Fenrir terminal has attached,
    /// so quitting and relaunching attaches the same ones again. A failed read keeps what was known.
    private func pollTmuxAttachments() {
        guard Date().timeIntervalSince(lastTmuxPoll) >= 10 else { return }
        lastTmuxPoll = Date()
        let core = self.core
        for host in Set(sessions.compactMap(\.host)) {
            Task {
                guard let list = try? await Task.detached(operation: { try core.remoteTmuxAttachments(host: host) }).value else { return }
                // A terminal whose link is down is missing from the host's list; keep its tmux until it is back.
                for s in sessions where s.host == host && s.state != .reconnecting { s.tmuxSession = list.first { $0.fenrirSession == s.id }?.name }
            }
        }
    }

    private var lastAgentPoll = Date.distantPast

    /// Hooks only fire on events, so a long subagent looks silent between them; every 30 s read its
    /// transcript mtime (stat over ssh for remote hosts) so it is not aged out while still working.
    private func pollAgentTranscripts(now: Int64) {
        guard Date().timeIntervalSince(lastAgentPoll) >= 30 else { return }
        lastAgentPoll = Date()
        let core = self.core
        for s in sessions where s.state != .exited {
            let ids = s.tracker.runningIds(nowMs: now)
            guard !ids.isEmpty, let sid = s.claudeSession, let cwd = s.claudeCwd else { continue }
            let host = s.host, tracker = s.tracker
            Task.detached {
                let scan = core.agentMtimes(host: host, cwd: cwd, claudeSession: sid, ids: ids)
                if !scan.isEmpty { tracker.refresh(scan: scan) }
            }
        }
    }

    private func target(for e: HookEvent) -> SessionItem? {
        // Exact match first: local sessions carry FENRIR_SESSION, remote ones the Fenrir tmux session name.
        // Inside tmux FENRIR_SESSION is whatever the tmux server started with, possibly an old id: trust the tmux name.
        if let t = e.tmuxSession {
            if let s = sessions.first(where: { $0.tmuxSession == t }) { return s }
        } else if let id = e.fenrirSession, let s = sessions.first(where: { $0.id == id }) { return s }
        guard let pid = e.projectId else { return nil }
        if let o = e.ordinal, let s = sessions.first(where: { $0.projectID == pid && UInt32($0.ordinal) == o }) { return s }
        // Otherwise only a session already known to run this Claude conversation; never guess, or events land on the wrong row.
        guard !e.claudeSession.isEmpty else { return nil }
        return sessions.first { $0.projectID == pid && $0.claudeSession == e.claudeSession }
    }

    func handle(_ e: HookEvent) {
        guard let s = target(for: e), s.state != .exited else { return }
        s.heardFromHook = true
        if !e.claudeSession.isEmpty { s.claudeSession = e.claudeSession; s.claudeCwd = e.cwd }
        if let n = s.pendingName {
            if !e.claudeSession.isEmpty, let cwd = s.claudeCwd, (try? core.renameClaudeSession(host: s.host, cwd: cwd, claudeSession: e.claudeSession, name: n)) == true { s.pendingName = nil }
        } else if let t = e.title { s.title = t } else if s.title == nil, let p = e.prompt { s.title = p }
        log("event \(e.kind) -> session \(s.id) (project \(s.projectID))")
        let at = Date(timeIntervalSince1970: Double(e.tsMs) / 1000)
        s.touch(at)
        s.settleToken = nil
        let u = s.tracker.apply(e: e, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        // A stop hook can make claude carry on after Stop fired. Show "done" only once the transcript
        // has stayed unwritten for 10 s after the Stop; until then the card keeps its state.
        guard u.notice == .done, let sid = s.claudeSession, let cwd = s.claudeCwd else { return show(u, on: s, message: e.message) }
        let token = UUID()
        s.settleToken = token
        let core = self.core, host = s.host, stopMs = e.tsMs, message = e.message
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            let written = await Task.detached { core.transcriptMtime(host: host, cwd: cwd, claudeSession: sid) }.value
            guard s.settleToken == token else { return }
            s.settleToken = nil
            if let written, written > stopMs + 2_000 { return }
            show(u, on: s, message: message)
        }
    }

    /// Puts a tracker update on the card and raises the bell for its notice.
    private func show(_ u: Update, on s: SessionItem, message: String?) {
        s.agents = s.tracker.agents(nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        switch u.state {
        case .working:
            s.state = .working
            s.lastMessage = nil
        case .idle:
            s.state = .idle
            if let n = u.notice { s.lastMessage = n == .agentsDone ? "Agents finished, idle" : "Finished, idle" }
        case .needsInput:
            s.state = .needsInput
            if u.notice != nil { s.lastMessage = message ?? "Needs your input" }
        case .agentsRunning:
            s.state = .agentsRunning
            s.lastMessage = "Agents running: \(u.agents)" + (u.firstAgent.map { ", \($0)" } ?? "")
        }
        guard u.notice != nil else { return }
        s.touch()
        let viewing = s.id == selectedSessionID && !showSftp && NSApp.isActive
        guard !viewing else { return }
        s.unread += 1
        NSApp.dockTile.badgeLabel = "\(totalUnread)"
        let name = projects.first { $0.id == s.projectID }?.name ?? "Project"
        Notifier.shared.post(title: name, body: s.lastMessage ?? "", sessionID: s.id)
    }

    func log(_ s: String) { FileHandle.standardError.write(Data("fenrir: \(s)\n".utf8)) }
}
