import AppKit
import SwiftUI

/// `<repo>/.harness/HANDOFF.md` of this project.
@MainActor
final class ContextModel: ObservableObject {
    @Published private(set) var handoff: String?
    private let core: FenrirCore
    private let project: Project
    private var watcher: FSWatcher?
    private var poll: Task<Void, Never>?

    init(core: FenrirCore, project: Project) {
        self.core = core
        self.project = project
        reload()
        if project.host == nil {
            let harness = project.path + "/.harness"
            watcher = FSWatcher(path: FileManager.default.fileExists(atPath: harness) ? harness : project.path) { [weak self] in self?.reload() }
        } else {
            poll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    self?.reload()
                }
            }
        }
    }

    deinit { poll?.cancel() }

    func reload() {
        guard let host = project.host else {
            handoff = try? String(contentsOfFile: project.path + "/.harness/HANDOFF.md", encoding: .utf8)
            return
        }
        let (core, path) = (core, project.path + "/.harness/HANDOFF.md")
        Task {
            handoff = try? await Task.detached { try core.readRemoteFile(host: host, path: path, maxBytes: 300_000) }.value
        }
    }
}

struct ContextTab: View {
    @StateObject private var model: ContextModel
    @EnvironmentObject var app: AppModel

    init(project: Project, core: FenrirCore) {
        _model = StateObject(wrappedValue: ContextModel(core: core, project: project))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Handoff", icon: "doc.text") {
                    if let h = model.handoff, !h.isEmpty {
                        MarkdownView(text: h)
                    } else {
                        note("No .harness/HANDOFF.md in this project yet.")
                    }
                }
            }
            .padding(14)
        }
        .onAppear { model.reload() }
    }

    private func section<C: View>(_ title: String, icon: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title.uppercased(), systemImage: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).tracking(0.6)
            content()
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundStyle(.secondary)
    }
}
