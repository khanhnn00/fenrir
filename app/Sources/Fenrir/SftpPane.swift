import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum Fmt {
    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy HH:mm"
        return f
    }()
    static func size(_ n: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
}

private struct DragPayload: Codable {
    let side: String
    let paths: [String]
}

extension SftpModel {
    /// Handles items dropped on a pane (or on one of its folders): the other pane's items, or files from Finder.
    func handleDrop(_ providers: [NSItemProvider], onto side: Side, dir: String?) -> Bool {
        var accepted = false
        // A drag out of one of the panes also carries file URLs or promises; the pane payload alone says what to do.
        let fromPane = providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.sftpItems.identifier) }
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.sftpItems.identifier) {
                accepted = true
                p.loadDataRepresentation(forTypeIdentifier: UTType.sftpItems.identifier) { data, _ in
                    guard let data, let d = try? JSONDecoder().decode(DragPayload.self, from: data), d.side != side.rawValue else { return }
                    Task { @MainActor in self.send(d.paths, from: Side(rawValue: d.side) ?? .local, into: dir ?? self.pane(side).path) }
                }
            } else if !fromPane, side == .remote, p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in self.send([url.path], from: .local, into: dir ?? self.remote.path) }
                }
            }
        }
        return accepted
    }
}

/// One side of the transfer view.
struct SftpPane: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var pane: PaneModel
    @ObservedObject var sftp: SftpModel
    @State private var dropTarget: String?
    @State private var pathText = ""
    @State private var renaming: SftpEntry?
    @State private var deleting: [SftpEntry] = []
    @State private var newFolder = false
    @State private var nameText = ""

    private var side: Side { pane.side }
    private var host: String? { side == .remote ? sftp.host : nil }
    private var title: String { side == .local ? "This Mac" : model.machines.first { $0.host == sftp.host }?.name ?? "No host" }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            columns
            Divider()
            if side == .remote && sftp.host == nil {
                EmptyState(icon: "server.rack", title: "Choose a host", detail: "Pick a machine above to browse its files.")
            } else {
                list
            }
            Divider()
            footer
        }
        .background(dropTarget == "." ? Color.accentColor.opacity(0.08) : Color.clear)
        .overlay { if dropTarget == "." { Rectangle().strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false) } }
        .onDrop(of: [.sftpItems, .fileURL], isTargeted: Binding(get: { dropTarget == "." }, set: { dropTarget = $0 ? "." : nil })) {
            sftp.handleDrop($0, onto: side, dir: nil)
        }
        .onChange(of: pane.path) { pathText = $0 }
        .onAppear { pathText = pane.path }
        .alert("New Folder", isPresented: $newFolder) {
            TextField("Name", text: $nameText)
            Button("Create") { sftp.mkdir(side, name: nameText) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $nameText)
            Button("Rename") { if let e = renaming { sftp.rename(side, e, to: nameText) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })) {
            Button("Delete", role: .destructive) { sftp.delete(side, deleting); deleting = [] }
        } message: {
            Text("This cannot be undone.")
        }
    }

    private var deleteTitle: String {
        deleting.count == 1 ? "Delete “\(deleting[0].name)” from \(title)?" : "Delete \(deleting.count) items from \(title)?"
    }

    private var selected: [SftpEntry] { pane.shown.filter { pane.selection.contains($0.path) } }

    private var toolbar: some View {
        HStack(spacing: 4) {
            Image(systemName: side == .local ? "laptopcomputer" : "server.rack").foregroundStyle(Color.accentColor)
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).frame(maxWidth: 110, alignment: .leading)
            BarButton(icon: "chevron.up", help: "Enclosing folder") { sftp.up(side) }.disabled(pane.path.isEmpty || pane.path == "/")
            TextField("", text: $pathText).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                .onSubmit { sftp.go(side, to: pathText) }
            BarButton(icon: "arrow.clockwise", help: "Refresh") { sftp.reload(side) }
            BarButton(icon: pane.showHidden ? "eye" : "eye.slash", help: pane.showHidden ? "Hide hidden files" : "Show hidden files", on: pane.showHidden) { pane.showHidden.toggle() }
            BarButton(icon: "folder.badge.plus", help: "New folder") { nameText = ""; newFolder = true }
            BarButton(icon: side == .local ? "arrow.right.circle" : "arrow.left.circle",
                      help: side == .local ? "Upload selected to the host" : "Download selected to this Mac") {
                sftp.send(selected.map(\.path), from: side)
            }.disabled(selected.isEmpty || sftp.host == nil)
        }
        .padding(.horizontal, Space.s).frame(height: 36)
    }

    private var columns: some View {
        HStack(spacing: 0) {
            colButton("Name", .name).frame(maxWidth: .infinity, alignment: .leading)
            colButton("Size", .size).frame(width: 76, alignment: .trailing)
            colButton("Modified", .modified).frame(width: 128, alignment: .trailing)
        }
        .padding(.horizontal, Space.m).frame(height: 22)
        .background(Color.primary.opacity(0.04))
    }

    private func colButton(_ label: String, _ key: SortKey) -> some View {
        Button { pane.sort(by: key) } label: {
            HStack(spacing: 3) {
                Text(label)
                if pane.sortKey == key { Image(systemName: pane.ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)) }
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }.buttonStyle(.plain)
    }

    private var list: some View {
        ZStack {
            List(selection: $pane.selection) {
                ForEach(pane.shown, id: \.path) { e in
                    row(e).tag(e.path)
                        .listRowInsets(EdgeInsets(top: 0, leading: Space.s, bottom: 0, trailing: Space.s))
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 24)
            if let err = pane.error {
                Label(err, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.red)
                    .padding(Space.m).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding()
                    .textSelection(.enabled)
            } else if pane.shown.isEmpty && !pane.loading {
                Text("Empty folder").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ e: SftpEntry) -> some View {
        HStack(spacing: 0) {
            Image(systemName: e.isDir ? "folder.fill" : "doc").foregroundStyle(e.isDir ? Color.accentColor : .secondary).frame(width: 22)
            Text(e.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            Text(e.isDir ? "—" : Fmt.size(e.size)).foregroundStyle(.secondary).frame(width: 76, alignment: .trailing)
            Text(Fmt.date.string(from: Date(timeIntervalSince1970: TimeInterval(e.modified)))).foregroundStyle(.secondary)
                .frame(width: 128, alignment: .trailing)
        }
        .font(.system(size: 12)).frame(height: 24)
        .background(dropTarget == e.path ? Color.accentColor.opacity(0.25) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if e.isDir { sftp.go(side, to: e.path) } else { sftp.send([e.path], from: side) } }
        .onHover { inside in DragOut.shared.setHover("\(side.rawValue):\(e.path)", dragSource(e), entered: inside) }
        .onDrop(of: [.sftpItems, .fileURL], isTargeted: e.isDir ? Binding(get: { dropTarget == e.path }, set: { dropTarget = $0 ? e.path : nil }) : .constant(false)) {
            e.isDir ? sftp.handleDrop($0, onto: side, dir: e.path) : false
        }
        .contextMenu {
            if e.isDir { Button("Open") { sftp.go(side, to: e.path) } }
            Button(side == .local ? "Upload" : "Download") { sftp.send(contextTargets(e), from: side) }.disabled(sftp.host == nil)
            Divider()
            Button("Rename…") { nameText = e.name; renaming = e }
            Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(e.path, forType: .string) }
            Button("New Folder…") { nameText = ""; newFolder = true }
            Divider()
            Button("Delete…", role: .destructive) { deleting = pane.selection.contains(e.path) ? selected : [e] }
        }
    }

    private func dragSource(_ e: SftpEntry) -> DragSource {
        let (side, host) = (side, host)
        let items = { [self] () -> [DragItem] in
            (pane.selection.contains(e.path) ? selected : [e]).map { DragItem(path: $0.path, name: $0.name, isDir: $0.isDir) }
        }
        let payload = { [self] () -> Data in
            let paths = items().map(\.path)
            return (try? JSONEncoder().encode(DragPayload(side: side.rawValue, paths: paths))) ?? Data()
        }
        return DragSource(host: host, items: items, payload: payload)
    }

    private func contextTargets(_ e: SftpEntry) -> [String] { pane.selection.contains(e.path) ? selected.map(\.path) : [e.path] }

    private var footer: some View {
        HStack {
            Text("\(pane.shown.count) items" + (pane.selection.isEmpty ? "" : " · \(pane.selection.count) selected"))
            Spacer()
            if pane.loading { ProgressView().controlSize(.mini) }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, Space.m).frame(height: 22)
    }
}
