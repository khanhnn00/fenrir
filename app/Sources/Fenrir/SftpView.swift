import SwiftUI

/// File transfer: this Mac on the left, a host on the right, drag between them; the queue sits below.
struct SftpView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var sftp: SftpModel
    @State private var queueOpen = true

    private var hosts: [Machine] { model.machines.filter { $0.host != nil } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                SftpPane(pane: sftp.local, sftp: sftp)
                Divider()
                SftpPane(pane: sftp.remote, sftp: sftp)
            }
            Divider()
            TransferQueue(sftp: sftp, open: $queueOpen)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay { if let item = sftp.pendingConflict { ConflictPrompt(sftp: sftp, item: item) } }
        .alert("Transfer", isPresented: Binding(get: { sftp.errorMessage != nil }, set: { if !$0 { sftp.errorMessage = nil } })) {
            Button("OK") {}
        } message: { Text(sftp.errorMessage ?? "") }
        .onAppear { sftp.start(); if sftp.host == nil { sftp.choose(host: hosts.first?.host) } }
    }

    private var header: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "arrow.left.arrow.right").foregroundStyle(Color.accentColor)
            Text("SFTP").font(.system(size: 13, weight: .semibold))
            Text("Drag items between the panes, or drop files from Finder onto the host.")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if hosts.isEmpty {
                Text("Add a machine to pick a host").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Menu {
                    ForEach(hosts, id: \.id) { m in
                        Button { sftp.choose(host: m.host) } label: { Label("\(m.name)  \(m.host ?? "")", systemImage: sftp.host == m.host ? "checkmark" : "server.rack") }
                    }
                } label: {
                    Label(hosts.first { $0.host == sftp.host }?.name ?? "Choose host", systemImage: "server.rack")
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
        .padding(.horizontal, Space.m).frame(height: 36)
    }
}

/// Asks what to do with a name that already exists at the destination.
struct ConflictPrompt: View {
    @ObservedObject var sftp: SftpModel
    let item: TransferItem
    @State private var all = false

    private var where_: String { item.direction == .upload ? sftp.host ?? "the host" : "This Mac" }

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
            VStack(alignment: .leading, spacing: Space.m) {
                Label("“\(item.name)” already exists", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.needsInput)
                Text("\(item.isDir ? "A folder" : "A file") with this name is already in \(item.dstDir) on \(where_).")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Apply to all remaining conflicts", isOn: $all).font(.system(size: 12))
                HStack {
                    Button("Cancel Transfer") { sftp.cancel(item) }
                    Spacer()
                    Button("Skip") { sftp.resolve(item, .skip, all: all) }
                    Button("Keep Both") { sftp.resolve(item, .rename, all: all) }
                    Button("Overwrite") { sftp.resolve(item, .overwrite, all: all) }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20).frame(width: 440)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
            .shadow(radius: 20)
        }
    }
}
