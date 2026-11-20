import SwiftUI

/// Left sidebar (machine header, session cards) | main area (tab bar over terminal and right panel).
struct ContentView: View {
    @EnvironmentObject var model: AppModel

    private var sidebarShown: Bool { model.showSidebar && model.activeMachine != nil }

    var body: some View {
        VStack(spacing: 0) {
            // The top bar's leading region keeps the sidebar width on every tab, landing included.
            TabBar(sidebarShown: model.showSidebar)
            HStack(spacing: 0) {
                if sidebarShown {
                    SidebarView().frame(width: model.sidebarWidth)
                        .overlay(alignment: .trailing) { SidebarResizeHandle() }
                    Divider()
                } else if model.activeMachine != nil {
                    SidebarRail()
                    Divider()
                }
                // The machine view stays mounted behind the landing zone so terminals are never detached.
                ZStack {
                    MachineView()
                    if model.activeMachine == nil { LandingView() }
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle(title)
        .animation(.easeInOut(duration: 0.18), value: sidebarShown)
        .sheet(isPresented: $model.showQuickSwitcher) { QuickSwitcher() }
        .sheet(isPresented: $model.showAddProject) { AddProjectSheet() }
        .alert("Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") {}
        } message: { Text(model.errorMessage ?? "") }
    }

    private var title: String {
        if model.activeMachine == nil { return "Fenrir" }
        return model.showSftp ? "SFTP" : model.activeProject?.name ?? model.activeMachine?.name ?? "Fenrir"
    }
}

/// The active tab's machine: terminal in the middle, files and context on the right.
struct MachineView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if !model.activeFiles.isEmpty && !model.showSftp { FileStrip() }
                ZStack {
                    TerminalStack().opacity(model.showSftp || model.shownDoc != nil || model.selectedSession == nil ? 0 : 1)
                    if model.showSftp {
                        SftpView(sftp: model.sftp)
                    } else if let d = model.shownDoc {
                        FileView(doc: d)
                    } else if model.selectedSession == nil {
                        EmptyState(icon: "terminal", title: "Select a project",
                                   detail: "Each project keeps its own terminal sessions running while you switch.")
                    }
                }
            }
            if model.showPanel && !model.showSftp {
                Divider()
                RightPanel()
            }
        }
    }
}

/// Drag strip on the sidebar's right edge; the top bar follows because both read `sidebarWidth`.
struct SidebarResizeHandle: View {
    @EnvironmentObject var model: AppModel
    @State private var startWidth: CGFloat?

    var body: some View {
        Color.clear.frame(width: 7).contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { v in
                    let start = startWidth ?? model.sidebarWidth
                    startWidth = start
                    model.sidebarWidth = min(max(start + v.translation.width, AppModel.sidebarRange.lowerBound), AppModel.sidebarRange.upperBound)
                }
                .onEnded { _ in startWidth = nil })
    }
}
