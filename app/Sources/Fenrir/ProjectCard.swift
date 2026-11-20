import SwiftUI

/// One sidebar card per project: header, machine and folder chips, and the project's sessions as rows
/// (running subagents nested under their session).
struct ProjectCard: View {
    let project: Project
    let machineName: String
    let sessions: [SessionItem]
    let selectedSessionID: Int64?
    /// The project is the one in view even if it has no session.
    let focused: Bool
    let onOpenProject: () -> Void
    let onSelect: (SessionItem) -> Void
    let onClose: (SessionItem) -> Void
    let onRenameProject: (String) -> Void
    let onRenameSession: (SessionItem, String) -> Void
    /// The card header is an edit field while this is true.
    @Binding var renaming: Bool
    @State private var renamingSession: Int64?
    @AppStorage private var collapsed: Bool
    @State private var hover = false
    @State private var agentsHidden = Set<Int64>()

    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    init(project: Project, machineName: String, sessions: [SessionItem], selectedSessionID: Int64?, focused: Bool,
         onOpenProject: @escaping () -> Void, onSelect: @escaping (SessionItem) -> Void, onClose: @escaping (SessionItem) -> Void,
         onRenameProject: @escaping (String) -> Void, onRenameSession: @escaping (SessionItem, String) -> Void, renaming: Binding<Bool>) {
        self.project = project
        self.machineName = machineName
        self.sessions = sessions
        self.selectedSessionID = selectedSessionID
        self.focused = focused
        self.onOpenProject = onOpenProject
        self.onSelect = onSelect
        self.onClose = onClose
        self.onRenameProject = onRenameProject
        self.onRenameSession = onRenameSession
        _renaming = renaming
        _collapsed = AppStorage(wrappedValue: false, "projectCollapsed.\(project.id)")
    }

    private var unread: Int { sessions.reduce(0) { $0 + $1.unread } }
    private var current: Bool { focused || sessions.contains { $0.id == selectedSessionID } }

    /// The state that most needs the user: input, then work, then agents, then the rest.
    private var aggregate: AgentState? {
        let order: [AgentState] = [.needsInput, .working, .agentsRunning, .reconnecting, .idle, .exited]
        return order.first { st in sessions.contains { $0.state == st } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if renaming { header } else { Button(action: onOpenProject) { header }.buttonStyle(.plain) }
            chips
            if sessions.isEmpty {
                Text("No session yet").font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 6).padding(.top, 2)
            } else {
                countRow
                if !collapsed {
                    ForEach(sessions) { s in
                        SessionRow(item: s, selected: s.id == selectedSessionID, editing: renamingSession == s.id,
                                   rename: { name in renamingSession = nil; if let name { onRenameSession(s, name) } }, agentsShown: !agentsHidden.contains(s.id),
                                   toggleAgents: { if !agentsHidden.insert(s.id).inserted { agentsHidden.remove(s.id) } },
                                   action: { onSelect(s) })
                            .contextMenu {
                                Button("Rename…") { renamingSession = s.id }
                                Button("Close Session") { onClose(s) }
                            }
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(shape)
        // A click anywhere on the card that is not a row or the count toggle opens the project's last used session.
        .onTapGesture(perform: onOpenProject)
        .background(shape.fill(fill))
        .overlay(shape.strokeBorder(current ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: 1))
        .overlay { if unread > 0 && !current { UnseenGlow(shape: shape) } }
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .animation(.easeOut(duration: 0.15), value: collapsed)
        .animation(.easeOut(duration: 0.15), value: current)
    }

    private var fill: Color {
        if current { return Color.accentColor.opacity(0.08) }
        return hover ? Color.primary.opacity(0.06) : Color(nsColor: .controlBackgroundColor).opacity(0.7)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if unread > 0 { BellBadge(count: unread) } else { StateDot(state: aggregate) }
            if renaming {
                InlineNameField(initial: project.name, font: .system(size: 14, weight: .semibold)) { name in
                    renaming = false
                    if let name { onRenameProject(name) }
                }
            } else {
                Text(project.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var chips: some View {
        HStack(spacing: 6) {
            Text(machineName).font(.system(size: 11, weight: .medium)).lineLimit(1)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
            Text((project.path as NSString).lastPathComponent).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .help(project.path.abbreviatingHome)
        .padding(.leading, 2)
    }

    private var countRow: some View {
        Button { collapsed.toggle() } label: {
            HStack {
                Text(sessions.count == 1 ? "1 session" : "\(sessions.count) sessions")
                Spacer()
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).rotationEffect(.degrees(collapsed ? -90 : 0))
            }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.top, 2)
        .help(collapsed ? "Show sessions" : "Hide sessions")
    }
}

/// One session of a project; its running subagents nest below it.
private struct SessionRow: View {
    @ObservedObject var item: SessionItem
    let selected: Bool
    let editing: Bool
    /// Called with the new name, or nil when the edit is cancelled.
    let rename: (String?) -> Void
    let agentsShown: Bool
    let toggleAgents: () -> Void
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if editing {
                    HStack(spacing: 8) {
                        StateIcon(state: item.state, unknown: !item.heardFromHook && item.state == .idle)
                        InlineNameField(initial: item.displayTitle, font: .system(size: 12.5), onDone: rename)
                    }
                } else {
                Button(action: action) {
                    HStack(spacing: 8) {
                        StateIcon(state: item.state, unknown: !item.heardFromHook && item.state == .idle)
                            .help(!item.heardFromHook && item.state == .idle ? "No agent status yet: Fenrir hooks are not reporting from this host" : "")
                        Text(item.displayTitle).font(.system(size: 12.5, weight: item.unread > 0 ? .bold : .regular))
                            .foregroundStyle(item.state == .exited ? .secondary : .primary).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        RelativeTime(date: item.lastActivity).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                }
                if !item.agents.isEmpty {
                    Button(action: toggleAgents) {
                        Image(systemName: "chevron.up").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(agentsShown ? 0 : 180)).frame(width: 14, height: 16)
                    }
                    .buttonStyle(.plain).help(agentsShown ? "Hide subagents" : "Show subagents")
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.16) : hover ? Color.primary.opacity(0.06) : .clear))
            if agentsShown && !item.agents.isEmpty {
                HStack(alignment: .top, spacing: 0) {
                    Rectangle().fill(Color.primary.opacity(0.18)).frame(width: 1)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(item.agents, id: \.id) { a in
                            HStack(spacing: 8) {
                                StateIcon(state: .working, tint: Theme.agents)
                                Text(a.desc).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 4)
                                RelativeTime(date: Date(timeIntervalSince1970: Double(a.mtime) / 1000)).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                        }
                    }
                }
                .padding(.leading, 14)
            }
        }
        .onHover { hover = $0 }
    }
}

/// Row icon: spinner while working, check when idle, bell-dot when it needs input, grey dot when ended.
private struct StateIcon: View {
    let state: AgentState
    var tint: Color?
    /// No hook event yet: show a neutral dot instead of a "done" check.
    var unknown = false

    var body: some View {
        Group {
            if unknown {
                Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.5).frame(width: 10, height: 10)
            } else {
            switch state {
            case .working, .agentsRunning, .reconnecting:
                TimelineView(.animation) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
                    Circle().trim(from: 0, to: 0.72).stroke(tint ?? state.color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 11, height: 11).rotationEffect(.degrees(t * 360))
                }
            case .idle:
                Image(systemName: "checkmark.circle").font(.system(size: 13)).foregroundStyle(state.color)
            case .needsInput:
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 13)).foregroundStyle(state.color)
            case .exited:
                Circle().fill(Color.secondary.opacity(0.45)).frame(width: 8, height: 8)
            }
            }
        }
        .frame(width: 16, height: 16)
    }
}

private struct StateDot: View {
    let state: AgentState?

    var body: some View {
        ZStack {
            if let ring = state.flatMap({ $0 == .working ? Theme.working : $0 == .agentsRunning ? Theme.agents : nil }) {
                TimelineView(.animation) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                    Circle().stroke(ring.opacity(1 - t), lineWidth: 1.5).frame(width: 9 + 9 * t, height: 9 + 9 * t)
                }
            }
            Circle().fill(state?.color ?? Color.secondary.opacity(0.35)).frame(width: 9, height: 9)
        }
        .frame(width: 22, height: 18)
    }
}

/// Bell with a count; swings while it is unseen.
struct BellBadge: View {
    let count: Int

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            // a short ring every 2.4 s, still in between
            let phase = t.truncatingRemainder(dividingBy: 2.4)
            let swing = phase < 0.7 ? sin(phase * 22) * 16 * (1 - phase / 0.7) : 0
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bell.fill").font(.system(size: 14)).foregroundStyle(Theme.needsInput)
                    .rotationEffect(.degrees(swing), anchor: .top)
                if count > 1 {
                    Text("\(count)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 4).background(Capsule().fill(Color.red)).offset(x: 7, y: -6)
                }
            }
        }
        .frame(width: 22)
    }
}

/// Soft pulsing orange border and halo for a card with unseen notifications.
private struct UnseenGlow<S: InsettableShape>: View {
    let shape: S

    var body: some View {
        TimelineView(.animation) { ctx in
            let p = (sin(ctx.date.timeIntervalSinceReferenceDate * 2.6) + 1) / 2
            shape.strokeBorder(Theme.needsInput.opacity(0.45 + 0.45 * p), lineWidth: 1.5)
                .shadow(color: Theme.needsInput.opacity(0.15 + 0.3 * p), radius: 3 + 5 * p)
        }
        .allowsHitTesting(false)
    }
}

struct RelativeTime: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            let s = Int(ctx.date.timeIntervalSince(date))
            Text(s < 60 ? "now" : s < 3600 ? "\(s / 60)m" : s < 86400 ? "\(s / 3600)h" : "\(s / 86400)d")
        }
    }
}

/// Text field that replaces a name in place: Return or leaving the field keeps the edit, Escape drops it.
struct InlineNameField: View {
    @State private var text: String
    @State private var finished = false
    @FocusState private var focused: Bool
    let font: Font
    let onDone: (String?) -> Void

    init(initial: String, font: Font, onDone: @escaping (String?) -> Void) {
        _text = State(initialValue: initial)
        self.font = font
        self.onDone = onDone
    }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain).font(font).lineLimit(1)
            .focused($focused)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1))
            .onAppear { focused = true }
            .onSubmit { finish(commit: true) }
            .onExitCommand { finish(commit: false) }
            .onChange(of: focused) { _, now in if !now { finish(commit: true) } }
    }

    private func finish(commit: Bool) {
        guard !finished else { return }
        finished = true
        onDone(commit ? text : nil)
    }
}
