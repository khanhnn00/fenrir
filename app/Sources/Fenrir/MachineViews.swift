import SwiftUI

/// The band across the top of the window: traffic lights, Home, SFTP, then one tab per machine and "+".
struct TabBar: View {
    @EnvironmentObject var model: AppModel
    /// True when the left sidebar is showing: the leading region then has the sidebar's width, so its divider is the sidebar's edge.
    let sidebarShown: Bool

    var body: some View {
        HStack(spacing: 0) {
            if sidebarShown {
                leading.frame(width: model.sidebarWidth, alignment: .leading).background(SidebarMaterial())
                Divider()
            } else {
                leading.fixedSize()
                Divider().frame(height: 16).padding(.horizontal, Space.xs)
            }
            tabs
        }
        .frame(height: Space.bar)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var leading: some View {
        HStack(spacing: Space.xs) {
            Color.clear.frame(width: 72) // the traffic lights sit here
            if sidebarShown { Spacer(minLength: 0) } // buttons sit against the divider and move with it
            BarButton(icon: "house", help: "Machines: back to the landing zone", on: model.activeMachine == nil) { model.goHome() }
            LabeledBarButton(icon: "arrow.up.arrow.down", title: "SFTP", help: "Copy files to and from a host over SFTP", on: model.showSftp) {
                if model.showSftp { model.showSftp = false } else { model.openSftp() }
            }
        }
        .padding(.leading, Space.s).padding(.trailing, sidebarShown ? Space.s : 0)
    }

    private var tabs: some View {
        HStack(spacing: Space.xs) {
            ForEach(model.tabs) { tab in TabItem(tab: tab, active: tab.id == model.activeTabID) }
            BarButton(icon: "plus", help: "New tab: open another machine, ⌘N") { model.newTab() }
            Spacer(minLength: 0)
            BarButton(icon: "sidebar.right", help: "Show or hide the Files and Context panel, ⌥⌘\\", on: model.showPanel) { model.showPanel.toggle() }
                .disabled(model.activeMachine == nil)
        }
        .padding(.horizontal, Space.s)
    }
}

/// Icon plus text for actions that must be recognisable at a glance; `on` tints it while its view is open.
struct LabeledBarButton: View {
    let icon: String
    let title: String
    let help: String
    var on = false
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(on ? Color.accentColor : Color.primary.opacity(0.75))
            .padding(.horizontal, 9).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(on ? Color.accentColor.opacity(0.13) : hover ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).onHover { hover = $0 }.opacity(enabled ? 1 : 0.35)
    }
}

/// A square icon button for the top band; `on` tints it when the thing it toggles is showing.
struct BarButton: View {
    let icon: String
    let help: String
    var on = false
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .regular))
                .foregroundStyle(on ? Color.accentColor : Color.primary.opacity(0.7))
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hover ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).onHover { hover = $0 }.opacity(enabled ? 1 : 0.35)
    }
}

private struct TabItem: View {
    @EnvironmentObject var model: AppModel
    let tab: TabState
    let active: Bool
    @State private var hover = false

    private var machine: Machine? { model.machine(of: tab) }
    private var unread: Int { machine.map { model.unread(on: $0) } ?? 0 }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: machine == nil ? "square.grid.2x2" : machine?.host == nil ? "laptopcomputer" : "network").font(.system(size: 11))
            Text(machine?.name ?? "New Tab").font(.system(size: 12, weight: active ? .semibold : .regular)).lineLimit(1)
            Spacer(minLength: 8)
            if unread > 0 { Image(systemName: "bell.fill").font(.system(size: 10)).foregroundStyle(Theme.needsInput) }
            Button { model.closeTab(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 14, height: 14) }
                .buttonStyle(.plain).opacity(hover || active ? 0.7 : 0).help("Close tab, ⇧⌘W. Sessions keep running")
        }
        .padding(.horizontal, 10).padding(.vertical, 4).frame(minWidth: 110, maxWidth: 220)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(active ? Color.accentColor.opacity(0.14) : hover ? Color.primary.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.activate(tab: tab.id) }
        .onHover { hover = $0 }
    }
}

/// What a tab shows until it is bound to a machine: Local, the added hosts, and "Add machine".
struct LandingView: View {
    @EnvironmentObject var model: AppModel
    @State private var renaming: Machine?
    @State private var removing: Machine?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    FenrirBadge(size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Machines").font(.system(size: 22, weight: .semibold))
                        Text("Pick where this tab works. Open more tabs to work on several machines at once.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 340), spacing: 14, alignment: .top)], spacing: 14) {
                    ForEach(model.machines, id: \.id) { m in
                        MachineCard(machine: m) { model.bind(tab: model.activeTabID, to: m) }
                            .contextMenu {
                                Button("Rename…") { renaming = m }
                                if m.host != nil {
                                    Button("SFTP…") { model.openSftp(for: m) }
                                    Button("Check Connection") { model.probe(m, force: true) }
                                    Divider()
                                    Button("Remove Machine…", role: .destructive) { removing = m }
                                }
                            }
                    }
                    AddMachineCard { model.showAddMachine = true }
                }
            }
            .padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.probeAll() }
        .sheet(isPresented: $model.showAddMachine) { AddMachineSheet() }
        .sheet(item: $renaming) { RenameMachineSheet(machine: $0) }
        .confirmationDialog("Remove \(removing?.name ?? "machine")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove Machine and Its Projects", role: .destructive) { if let m = removing { model.remove(m) }; removing = nil }
        } message: {
            Text("Its projects and sessions in Fenrir are removed. Anything running in tmux on the host keeps running.")
        }
    }
}

extension Machine: Identifiable {}

private struct MachineCard: View {
    @EnvironmentObject var model: AppModel
    let machine: Machine
    let action: () -> Void
    @State private var hover = false
    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    private var status: MachineStatus { machine.host == nil ? .online : model.machineStatus[machine.id] ?? .checking }
    private var unread: Int { model.unread(on: machine) }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Image(systemName: machine.host == nil ? "laptopcomputer" : "server.rack").font(.system(size: 20)).foregroundStyle(Color.accentColor)
                    Spacer()
                    if unread > 0 { BellBadge(count: unread) }
                    if machine.host != nil { TransferChip { model.openSftp(for: machine) } }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(machine.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(machine.host ?? "This Mac").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Circle().fill(dot).frame(width: 8, height: 8)
                    Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(counts).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(14).frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
            .background(shape.fill(hover ? Color.primary.opacity(0.07) : Color(nsColor: .controlBackgroundColor).opacity(0.7)))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
            .overlay { if unread > 0 { UnseenGlowCard(shape: shape) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }

    private var dot: Color {
        switch status {
        case .online: return Theme.idle
        case .checking: return Theme.needsInput
        case .offline: return .red
        }
    }

    private var statusText: String {
        switch status {
        case .online: return machine.host == nil ? "Always on" : "Connected"
        case .checking: return "Checking…"
        case .offline(let why): return why
        }
    }

    private var counts: String {
        let p = model.projects(on: machine).count, s = model.sessions(on: machine).count
        return "\(p) project\(p == 1 ? "" : "s") · \(s) session\(s == 1 ? "" : "s")"
    }
}

private struct UnseenGlowCard<S: InsettableShape>: View {
    let shape: S
    var body: some View {
        TimelineView(.animation) { ctx in
            let p = (sin(ctx.date.timeIntervalSinceReferenceDate * 2.6) + 1) / 2
            shape.strokeBorder(Theme.needsInput.opacity(0.45 + 0.45 * p), lineWidth: 1.5)
        }.allowsHitTesting(false)
    }
}

private struct AddMachineCard: View {
    let action: () -> Void
    @State private var hover = false
    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus.circle").font(.system(size: 24))
                Text("Add Machine").font(.system(size: 13, weight: .medium))
                Text("A host from ~/.ssh/config").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .foregroundStyle(hover ? Color.accentColor : .secondary)
            .frame(maxWidth: .infinity, minHeight: 138)
            .overlay(shape.strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])).foregroundStyle(Color.primary.opacity(hover ? 0.35 : 0.2)))
            .contentShape(shape)
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }
}

/// Pick or type an ssh host; the connection is tested before the machine is saved.
struct AddMachineSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var name = ""
    @State private var hosts: [String] = []
    @State private var testing = false
    @State private var coder: [CoderWorkspace]?
    @State private var coderFailure: String?
    @State private var failure: String?

    init(host: String = "", name: String = "") {
        _host = State(initialValue: host)
        _name = State(initialValue: name)
    }

    private var trimmed: String { host.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add Machine").font(.system(size: 17, weight: .semibold))
                Text("Sessions run in tmux over ssh, so they survive disconnects. The host must log in without a password prompt.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                label("Host")
                HStack {
                    TextField("", text: $host, prompt: Text("host alias from ~/.ssh/config")).textFieldStyle(.roundedBorder)
                    Menu {
                        ForEach(hosts, id: \.self) { h in Button(h) { host = h } }
                    } label: { Image(systemName: "chevron.down") }
                        .menuStyle(.borderlessButton).fixedSize().disabled(hosts.isEmpty)
                        .help(hosts.isEmpty ? "No Host entries in ~/.ssh/config" : "Hosts from ~/.ssh/config")
                }
                label("Name").padding(.top, 4)
                TextField("", text: $name, prompt: Text(trimmed.isEmpty ? "same as the host" : trimmed)).textFieldStyle(.roundedBorder)
            }
            coderSection
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack {
                if testing { ProgressView().controlSize(.small); Text("Testing ssh \(trimmed)…").font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Test & Add") { add() }.keyboardShortcut(.defaultAction).disabled(trimmed.isEmpty || testing)
            }
        }
        .padding(20).frame(width: 460)
        .onAppear {
            let added = Set(model.machines.compactMap(\.host))
            hosts = model.core.sshHosts().filter { !added.contains($0) }
            loadCoder()
        }
    }

    /// Workspaces from `coder list` (read-only). A stopped workspace is shown but not selectable: `coder ssh` would start it.
    @ViewBuilder private var coderSection: some View {
        if coder == nil && coderFailure == nil {
            HStack(spacing: 6) { ProgressView().controlSize(.small); label("Coder workspaces…") }
        } else if let coder, !coder.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                label("Coder workspaces")
                ForEach(coder, id: \.host) { w in
                    let running = w.status == "running"
                    let added = model.machines.contains { $0.host == w.host }
                    Button { host = w.host; if name.isEmpty { name = w.name } } label: {
                        HStack(spacing: 8) {
                            Circle().fill(running ? Color.green : Color.secondary).frame(width: 7, height: 7)
                            Text(w.name).font(.system(size: 12, weight: .medium))
                            Text(w.host).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                            Text(added ? "added" : running ? w.status : "\(w.status), start it in Coder first").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: 6).fill(trimmed == w.host ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04)))
                    }
                    .buttonStyle(.plain).disabled(!running || added).opacity(running && !added ? 1 : 0.55)
                }
            }
        } else if let coderFailure {
            Text("Coder: \(coderFailure)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private func loadCoder() {
        let core = model.core
        Task {
            do { coder = try await Task.detached { try core.coderWorkspaces() }.value }
            catch { coderFailure = "\(error)" }
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
    }

    private func add() {
        let (core, h, n) = (model.core, trimmed, name)
        testing = true; failure = nil
        Task {
            do {
                _ = try await Task.detached { try core.testMachine(host: h) }.value
                try model.addMachine(name: n, host: h)
                dismiss()
            } catch { failure = "\(error)" }
            testing = false
        }
    }
}

private struct RenameMachineSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let machine: Machine
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Machine").font(.system(size: 15, weight: .semibold))
            TextField("", text: $name).textFieldStyle(.roundedBorder).onSubmit { save() }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename") { save() }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 340)
        .onAppear { name = machine.name }
    }

    private func save() {
        model.rename(machine, to: name)
        dismiss()
    }
}

/// The machine card's shortcut to the file transfer view.
private struct TransferChip: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Label("SFTP", systemImage: "arrow.up.arrow.down").font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(hover ? Color.accentColor.opacity(0.2) : Color.accentColor.opacity(0.1)))
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain).onHover { hover = $0 }.help("Transfer files with this host over SFTP")
    }
}
