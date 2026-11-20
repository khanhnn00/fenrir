import SwiftUI
import AppKit

/// Adds a project to the machine of the current tab: a folder picker on Local, an absolute path
/// (with Browse over ssh) on a remote machine.
struct AddProjectSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var path: String
    @State private var browsing = false
    private let hostOverride: String?

    /// `host` is only for offscreen renders; the sheet normally follows the active tab's machine.
    init(host: String? = nil, path: String = "", name: String = "") {
        hostOverride = host
        _path = State(initialValue: path)
        _name = State(initialValue: name)
    }

    private var host: String? { hostOverride ?? model.activeMachine?.host }
    private var machineName: String { hostOverride ?? model.activeMachine?.name ?? "Local" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add Project").font(.system(size: 17, weight: .semibold))
                Text(host == nil ? "A repo folder on this Mac. Sessions open in it."
                                 : "A repo folder on \(machineName), opened over ssh.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                label(host == nil ? "Folder" : "Folder on \(machineName)")
                HStack {
                    TextField("", text: $path, prompt: Text(host == nil ? "~/work/my-repo" : "/home/me/my-repo")).textFieldStyle(.roundedBorder)
                    Button(host == nil ? "Choose…" : "Browse…") { host == nil ? chooseFolder() : (browsing = true) }
                }
                label("Name").padding(.top, 4)
                TextField("", text: $name, prompt: Text("my-repo")).textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { add() }.keyboardShortcut(.defaultAction).disabled(name.isEmpty || path.isEmpty)
            }
        }
        .padding(20).frame(width: 460)
        .sheet(isPresented: $browsing) {
            RemoteFolderPicker(host: host ?? "", start: path) { picked in
                path = picked
                if name.isEmpty { name = (picked as NSString).lastPathComponent }
            }
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
    }

    private func add() {
        if let host {
            model.add(name: name, path: path.trimmingCharacters(in: .whitespaces), host: host)
        } else {
            model.add(name: name, path: (path as NSString).expandingTildeInPath, host: nil)
        }
        dismiss()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
            if name.isEmpty { name = url.lastPathComponent }
        }
    }
}

/// Lists folders on the host over ssh, starting at `start` (or the remote home).
private struct RemoteFolderPicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let host: String
    let start: String
    let onPick: (String) -> Void
    @State private var current = ""
    @State private var folders: [FileEntry] = []
    @State private var loading = true
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { go((current as NSString).deletingLastPathComponent) } label: { Image(systemName: "arrow.up") }
                    .disabled(current.isEmpty || current == "/").help("Parent folder")
                Text("\(host):\(current)").font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.head)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            ScrollView {
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.red).padding(8)
                } else if folders.isEmpty && !loading {
                    Text("No subfolders").font(.system(size: 12)).foregroundStyle(.secondary).padding(8)
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(folders, id: \.path) { f in
                        Button { go(f.path) } label: {
                            Label(f.name, systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4).padding(.horizontal, 8)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 240).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use This Folder") { onPick(current); dismiss() }.keyboardShortcut(.defaultAction).disabled(current.isEmpty || failure != nil)
            }
        }
        .padding(18).frame(width: 460)
        .task {
            if start.hasPrefix("/") { go(start) } else { await loadHome() }
        }
    }

    private func loadHome() async {
        let (core, host) = (model.core, host)
        do { go(try await Task.detached { try core.remoteHome(host: host) }.value) }
        catch { loading = false; failure = "\(error)" }
    }

    private func go(_ dir: String) {
        let (core, host) = (model.core, host)
        loading = true; failure = nil
        Task {
            do {
                let all = try await Task.detached { try core.listRemoteDir(host: host, dir: dir) }.value
                current = dir
                folders = all.filter(\.isDir)
            } catch { failure = "\(error)" }
            loading = false
        }
    }
}
