import SwiftUI

struct RightPanel: View {
    @EnvironmentObject var model: AppModel
    

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.panelTab) {
                ForEach(PanelTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(10)
            Divider()
            if let p = model.activeProject {
                switch model.panelTab {
                case .files: FilesTab(project: p, core: model.core).id(p.id)
                case .context: ContextTab(project: p, core: model.core).id(p.id)
                case .ports:
                    if let host = p.host { PortsTab(host: host, core: model.core).id(host) }
                    else { EmptyState(icon: "arrow.left.arrow.right", title: "Ports are for remote machines", detail: "Select a project on a remote machine to forward its ports.") }
                }
            } else {
                EmptyState(icon: "sidebar.right", title: "No project selected", detail: "Pick a session to see its files and context.")
            }
        }
        .frame(width: 290)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
