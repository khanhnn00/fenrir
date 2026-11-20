import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @State private var renamingProject: Int64?
    @State private var dragging: Int64?

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader()
            ScrollView {
                LazyVStack(spacing: 8) {
                    if entries.isEmpty { EmptyProjects() }
                    list(entries)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            Divider()
            HStack {
                Button { if let p = model.activeProject { model.newSession(in: p) } } label: { Label("New Session", systemImage: "plus.rectangle") }
                    .buttonStyle(.borderless).disabled(model.activeProject == nil)
                    .lineLimit(1).fixedSize()
                    .help("Open another terminal in the selected project, ⌘T")
                Spacer().frame(width: 10)
                Button { model.showAddProject = true } label: { Label("Add Project", systemImage: "folder.badge.plus") }
                    .buttonStyle(.borderless).lineLimit(1).fixedSize()
                    .help("Add a repo folder as a project")
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.borderless).help("Settings")
            }
            .font(.system(size: 12)).padding(.horizontal, Space.l).padding(.vertical, Space.m - 2)
        }
        .background(SidebarMaterial())
    }

    private var entries: [Project] { model.navProjects(model.activeMachine) }

    @ViewBuilder private func list(_ projects: [Project]) -> some View {
        ForEach(projects, id: \.id) { p in
            ProjectCard(project: p, machineName: model.machine(of: p)?.name ?? "Local", sessions: model.sessions(of: p),
                        selectedSessionID: model.selectedSessionID,
                        focused: model.focusedProjectID == p.id,
                        onOpenProject: { model.open(project: p) }, onSelect: { model.select(sessionID: $0.id) },
                        onClose: { model.requestClose($0) },
                        onRenameProject: { model.rename(p, to: $0) }, onRenameSession: { model.rename($0, to: $1) },
                        renaming: Binding(get: { renamingProject == p.id }, set: { renamingProject = $0 ? p.id : nil }))
                .onDrag {
                    dragging = p.id
                    return NSItemProvider(object: String(p.id) as NSString)
                }
                .onDrop(of: [.text], delegate: CardDrop(target: p.id, dragging: $dragging, model: model))
                .contextMenu {
                    Button("New Session in \(p.name)") { model.newSession(in: p) }
                    Button("Rename…") { renamingProject = p.id }
                    Divider()
                    Button("Remove Project", role: .destructive) { model.remove(p) }
                }
        }
    }
}

/// Mark and current machine, under the band that holds the traffic lights.
private struct SidebarHeader: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                FenrirBadge(size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.activeMachine?.name ?? "Fenrir").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(model.activeMachine?.host ?? "This Mac").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                BarButton(icon: "sidebar.left", help: "Hide sidebar, ⌘\\ or ⌃⌘S", on: true) { model.showSidebar.toggle() }
            }
            .padding(.horizontal, Space.l).padding(.top, Space.m).padding(.bottom, Space.m)
        }
    }
}

/// What is left of the sidebar while it is hidden: the toggle that brings it back.
struct SidebarRail: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: Space.xs) {
            BarButton(icon: "sidebar.left", help: "Show sidebar, ⌘\\ or ⌃⌘S") { model.showSidebar = true }
            Spacer()
        }
        .padding(.top, Space.s).padding(.horizontal, Space.xs).frame(width: 40)
        .background(SidebarMaterial())
    }
}

private struct EmptyProjects: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.plus").font(.system(size: 26)).foregroundStyle(.secondary)
            Text("No projects yet").font(.system(size: 13, weight: .medium))
            Text("Add a repo folder to get a terminal and live agent status for it.")
                .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Add Project") { model.showAddProject = true }.controlSize(.small)
        }
        .padding(.vertical, 24).padding(.horizontal, 8)
    }
}

/// Dropping a card on another puts it there; the cards shuffle while the pointer is over them.
private struct CardDrop: DropDelegate {
    let target: Int64
    @Binding var dragging: Int64?
    let model: AppModel

    func dropEntered(info: DropInfo) {
        guard let id = dragging, id != target else { return }
        withAnimation(.easeOut(duration: 0.15)) { model.moveProject(id, before: target) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}
