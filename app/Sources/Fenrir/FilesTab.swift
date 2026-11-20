import AppKit
import SwiftUI

private let findResultCap: UInt32 = 200

struct FileRow: Identifiable {
    let entry: FileEntry
    let depth: Int
    var id: String { entry.path }
}

/// Lazily expanded file tree for one project root. Local roots refresh on FSEvents; remote roots
/// are listed over ssh (one reused connection) and polled.
@MainActor
final class FilesModel: ObservableObject {
    @Published private(set) var rows: [FileRow] = []
    /// Remote only: why the last listing failed.
    @Published private(set) var failure: String?
    @Published private(set) var loaded = false
    /// Open folders, kept per tree across view rebuilds (switching tabs recreates this model).
    private static var openFolders: [String: Set<String>] = [:]
    private var key: String { (host ?? "") + ":" + root }
    private var expanded: Set<String> = [] { didSet { Self.openFolders[key] = expanded } }
    private let core: FenrirCore
    private let root: String
    private let host: String?
    private var watcher: FSWatcher?
    private var poll: Task<Void, Never>?
    private var listing = false
    /// Remote listings per folder, so expanding and collapsing redraw at once instead of re-listing the whole tree.
    private var cache: [String: [FileEntry]] = [:]

    init(core: FenrirCore, root: String, host: String?) {
        self.core = core
        self.root = root
        self.host = host
        expanded = Self.openFolders[(host ?? "") + ":" + root] ?? []
        reload()
        if host == nil {
            watcher = FSWatcher(path: root) { [weak self] in self?.reload() }
        } else {
            poll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    self?.reload()
                }
            }
        }
    }

    deinit { poll?.cancel() }

    func isOpen(_ e: FileEntry) -> Bool { expanded.contains(e.path) }
    var rootPath: String { root }
    func report(_ error: Error) { failure = error.localizedDescription }

    func reload() {
        if let host { return reloadRemote(host) }
        loaded = true
        var out: [FileRow] = []
        func walk(_ dir: String, _ depth: Int) {
            for e in core.listDir(dir: dir) {
                out.append(FileRow(entry: e, depth: depth))
                if e.isDir && expanded.contains(e.path) { walk(e.path, depth + 1) }
            }
        }
        walk(root, 0)
        rows = out
    }

    private func reloadRemote(_ host: String) {
        guard !listing else { return }
        listing = true
        let (core, root, open) = (core, root, expanded)
        Task {
            let result = await Task.detached { () -> Result<[FileRow], Error> in
                do {
                    var out: [FileRow] = []
                    func walk(_ dir: String, _ depth: Int) throws {
                        for e in try core.listRemoteDir(host: host, dir: dir) {
                            out.append(FileRow(entry: e, depth: depth))
                            if e.isDir && open.contains(e.path) { try walk(e.path, depth + 1) }
                        }
                    }
                    try walk(root, 0)
                    return .success(out)
                } catch { return .failure(error) }
            }.value
            switch result {
            case .success(let r):
                cache[root] = r.filter { $0.depth == 0 }.map(\.entry)
                fillCache(from: r)
                if r.map(\.id) != rows.map(\.id) { rows = r }; failure = nil
                prefetch(r.map(\.entry).filter(\.isDir).map(\.path))
            case .failure(let e): failure = "\(e)"
            }
            loaded = true
            listing = false
        }
    }

    /// Downloads a remote file or folder into `dir` (a name already there gets a numbered copy),
    /// then opens it with the default app or shows it in Finder.
    func download(_ e: FileEntry, to dir: URL, open: Bool) {
        guard let host else { return }
        let core = core
        Task {
            do {
                let dst = try await Task.detached { () throws -> String in
                    let id = try core.startTransfer(host: host, direction: .download, src: e.path, dstDir: dir.path, policy: .rename)
                    while true {
                        if let t = core.transfers().first(where: { $0.id == id }) {
                            switch t.state {
                            case .done: return t.dst
                            case .failed, .cancelled, .skipped:
                                throw NSError(domain: "Fenrir", code: 1, userInfo: [NSLocalizedDescriptionKey: "Download of \(t.name) failed: \(t.error)"])
                            default: break
                            }
                        }
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                }.value
                let url = URL(fileURLWithPath: dst)
                if open { NSWorkspace.shared.open(url) } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } catch { failure = error.localizedDescription }
        }
    }

    /// Creates an empty file or a folder named `name` in `dir` (local or on the host), refuses an
    /// existing name, then opens `dir` in the tree and lists it again. Returns the new path.
    func create(name: String, folder: Bool, in dir: String) async throws -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != ".", n != "..", !n.contains("/") else {
            throw NSError(domain: "Fenrir", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid name"])
        }
        let core = core, host = host
        let path = try await Task.detached { () throws -> String in
            if folder { return try core.sftpMkdir(host: host, dir: dir, name: n) }
            let p = (dir as NSString).appendingPathComponent(n)
            if let host {
                if try core.sftpListRemote(host: host, dir: dir).contains(where: { $0.name == n }) {
                    throw NSError(domain: "Fenrir", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(n) already exists"])
                }
                try core.writeRemoteFile(host: host, path: p, data: Data())
            } else {
                guard !FileManager.default.fileExists(atPath: p) else {
                    throw NSError(domain: "Fenrir", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(n) already exists"])
                }
                guard FileManager.default.createFile(atPath: p, contents: Data()) else {
                    throw NSError(domain: "Fenrir", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create \(n)"])
                }
            }
            return p
        }.value
        cache[dir] = nil
        if dir != root { expanded.insert(dir) }
        reload()
        return path
    }

    /// Renames a file or folder in place (local or on the host) and lists its folder again.
    func rename(_ e: FileEntry, to name: String) async throws {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != e.name else { return }
        let core = core, host = host, path = e.path
        _ = try await Task.detached { try core.sftpRename(host: host, path: path, newName: n) }.value
        forget(path)
    }

    /// Local items go to the Trash; on a host they are removed for good.
    func delete(_ e: FileEntry) async throws {
        let core = core, host = host, path = e.path
        try await Task.detached {
            if let host { try core.sftpDelete(host: host, path: path) }
            else { try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) }
        }.value
        forget(path)
    }

    /// Drops cached listings and open state under `path` and of its folder, then lists again.
    private func forget(_ path: String) {
        let parent = (path as NSString).deletingLastPathComponent
        cache[parent] = nil
        for k in cache.keys where k == path || k.hasPrefix(path + "/") { cache[k] = nil }
        expanded = expanded.filter { $0 != path && !$0.hasPrefix(path + "/") }
        reload()
    }

    /// Folder that Find searches below; `nil` = the project root.
    @Published var searchScope: String?

    func relativePath(_ path: String) -> String {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }

    /// Fuzzy file search below the root; a newer query supersedes an older one still running.
    @Published private(set) var results: [FileEntry] = []
    @Published private(set) var searching = false
    private var searchTask: Task<Void, Never>?

    func search(_ query: String) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = []; searching = false; return }
        searching = true
        let (core, root, host) = (core, searchScope ?? root, host)
        searchTask = Task {
            try? await Task.sleep(nanoseconds: host == nil ? 60_000_000 : 300_000_000)
            if Task.isCancelled { return }
            let found = await Task.detached { () -> Result<[FileEntry], Error> in
                do {
                    if let host { return .success(try core.findRemoteFiles(host: host, root: root, query: q, cap: findResultCap)) }
                    return .success(core.findFiles(root: root, query: q, cap: findResultCap))
                } catch { return .failure(error) }
            }.value
            if Task.isCancelled { return }
            switch found {
            case .success(let r): results = r; failure = nil
            case .failure(let e): results = []; failure = "\(e)"
            }
            searching = false
        }
    }

    /// Path shown under a result: relative to the project root.
    func relative(_ e: FileEntry) -> String {
        e.path.hasPrefix(root + "/") ? String(e.path.dropFirst(root.count + 1)) : e.path
    }

    func toggle(_ e: FileEntry) {
        if expanded.contains(e.path) { expanded.remove(e.path) } else { expanded.insert(e.path) }
        guard let host else { return reload() }
        // Remote: redraw from the cache now; list only the opened folder if it was never listed.
        rows = rowsFromCache()
        if expanded.contains(e.path) { prefetch([e.path] + (cache[e.path] ?? []).filter(\.isDir).map(\.path)) }
    }

    private var prefetching = false
    /// Lists folders before they are opened (one ssh call each over the shared connection), so a
    /// first expand draws from the cache instead of waiting on the network.
    private func prefetch(_ dirs: [String]) {
        guard let host, !prefetching else { return }
        let todo = Array(dirs.filter { cache[$0] == nil }.prefix(40))
        guard !todo.isEmpty else { return }
        prefetching = true
        let core = core
        Task {
            for dir in todo {
                let kids = await Task.detached { try? core.listRemoteDir(host: host, dir: dir) }.value
                if let kids { cache[dir] = kids; if expanded.contains(dir) { rows = rowsFromCache() } }
            }
            prefetching = false
            // Folders revealed meanwhile get their own pass.
            prefetch(rows.map(\.entry).filter(\.isDir).map(\.path))
        }
    }

    /// Remembers each expanded folder's children from a full walk (rows are in tree order).
    private func fillCache(from r: [FileRow]) {
        for (i, row) in r.enumerated() where row.entry.isDir && expanded.contains(row.entry.path) {
            var kids: [FileEntry] = []
            var j = i + 1
            while j < r.count && r[j].depth > row.depth {
                if r[j].depth == row.depth + 1 { kids.append(r[j].entry) }
                j += 1
            }
            cache[row.entry.path] = kids
        }
    }

    private func rowsFromCache() -> [FileRow] {
        var out: [FileRow] = []
        func walk(_ dir: String, _ depth: Int) {
            for e in cache[dir] ?? [] {
                out.append(FileRow(entry: e, depth: depth))
                if e.isDir && expanded.contains(e.path) { walk(e.path, depth + 1) }
            }
        }
        walk(root, 0)
        return out
    }
}

struct FilesTab: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var model: FilesModel
    @State private var selected: String?
    @State private var hit = 0
    @State private var refreshing = false
    @FocusState private var findFocused: Bool

    private let project: Project

    init(project: Project, core: FenrirCore) {
        self.project = project
        _model = StateObject(wrappedValue: FilesModel(core: core, root: project.path, host: project.host))
        remote = project.host != nil
        host = project.host
    }

    private let remote: Bool
    private let host: String?

    private func dragSource(_ e: FileEntry) -> DragSource {
        DragSource(host: host, items: { [DragItem(path: e.path, name: e.name, isDir: e.isDir)] })
    }
    private var query: Binding<String> { $app.findQuery }
    private var finding: Bool { !app.findQuery.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            findBar
            Divider()
            if finding { resultList } else { tree }
        }
        .onChange(of: app.findFocusToken) { _ in findFocused = true }
        .onChange(of: app.findQuery) { q in hit = 0; model.search(q) }
        .onAppear { model.search(app.findQuery) }
    }

    private var findBar: some View {
        HStack(spacing: Space.s - 2) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Find files ⌘P", text: query)
                    .textFieldStyle(.plain).font(.system(size: 12)).focused($findFocused)
                    .onKeyPress(.downArrow) { hit = min(hit + 1, max(model.results.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { hit = max(hit - 1, 0); return .handled }
                    .onKeyPress(.escape) { app.findQuery = ""; model.searchScope = nil; findFocused = false; app.focusTerminal(); return .handled }
                    .onKeyPress(.return) { openHit(reveal: NSEvent.modifierFlags.contains(.command)); return .handled }
                if finding {
                    Button { app.findQuery = ""; model.searchScope = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain).help("Clear")
                }
            }
            .padding(.horizontal, Space.s).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(findFocused ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1))
            BarButton(icon: "arrow.clockwise", help: "Refresh files") { refresh() }
                .rotationEffect(.degrees(refreshing ? 360 : 0)).animation(refreshing ? .linear(duration: 0.6) : nil, value: refreshing)
        }
        .padding(.horizontal, Space.m - 2).padding(.vertical, Space.s)
    }

    private func refresh() {
        refreshing = true
        model.reload()
        if finding { model.search(app.findQuery) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { refreshing = false }
    }

    @ViewBuilder private var rootMenu: some View {
        Button("New File…") { create(folder: false, in: model.rootPath) }
        Button("New Folder…") { create(folder: true, in: model.rootPath) }
    }

    private func rename(_ e: FileEntry) {
        let alert = NSAlert()
        alert.messageText = "Rename \(e.name)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = e.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue
        Task { do { try await model.rename(e, to: name) } catch { model.report(error) } }
    }

    private func delete(_ e: FileEntry) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = remote ? "Delete \(e.name)?" : "Move \(e.name) to the Trash?"
        alert.informativeText = remote
            ? (e.isDir ? "The folder and everything in it are removed from the host. This cannot be undone." : "The file is removed from the host. This cannot be undone.")
            : "You can put it back from the Trash."
        alert.addButton(withTitle: remote ? "Delete" : "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { do { try await model.delete(e) } catch { model.report(error) } }
    }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// New session in this project, started in `dir`.
    private func openInTerminal(_ dir: String) {
        app.newSession(in: project)
        guard let s = app.sessions.last(where: { $0.projectID == project.id }) else { return }
        let q = "'" + dir.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try? app.core.writeSession(id: s.id, data: Data("cd \(q)\n".utf8))
    }

    private func findIn(_ dir: String) {
        model.searchScope = dir
        app.findQuery = ""
        findFocused = true
    }

    /// Asks for a name, creates it in `dir`, and opens a new file in a tab.
    private func create(folder: Bool, in dir: String) {
        let alert = NSAlert()
        alert.messageText = folder ? "New Folder" : "New File"
        alert.informativeText = "In \((dir as NSString).lastPathComponent)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = folder ? "Folder name" : "File name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue
        Task {
            do {
                let path = try await model.create(name: name, folder: folder, in: dir)
                selected = path
                if !folder { app.openFile(path: path, host: host) }
            } catch { model.report(error) }
        }
    }

    private func open(_ e: FileEntry, reveal: Bool = false) {
        if e.isDir { return }
        if !remote && reveal { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: e.path)]) }
        else { app.openFile(path: e.path, host: host) }
    }

    private func openHit(reveal: Bool) {
        if model.results.indices.contains(hit) { open(model.results[hit], reveal: reveal) }
    }

    @ViewBuilder private var resultList: some View {
        if model.results.isEmpty {
            if model.searching { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let f = model.failure { EmptyState(icon: "wifi.exclamationmark", title: "Search failed", detail: f) }
            else { EmptyState(icon: "magnifyingglass", title: "No matching files", detail: "Letters are matched in order anywhere in the path.") }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.results.enumerated()), id: \.element.path) { i, e in
                            ResultRow(entry: e, dir: parent(model.relative(e)), active: i == hit)
                                .id(i)
                                .onTapGesture { hit = i; open(e) }
                                .onHover { DragOut.shared.setHover("result:\(e.path)", dragSource(e), entered: $0) }
                        }
                    }
                    .padding(.vertical, Space.xs)
                }
                .onChange(of: hit) { i in proxy.scrollTo(i) }
            }
        }
    }

    private func parent(_ rel: String) -> String {
        guard let i = rel.lastIndex(of: "/") else { return "" }
        return String(rel[..<i])
    }

    @ViewBuilder private var tree: some View {
        if model.rows.isEmpty && !model.loaded {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.rows.isEmpty, let f = model.failure {
            EmptyState(icon: "wifi.exclamationmark", title: "Cannot list files", detail: f)
        } else if model.rows.isEmpty {
            EmptyState(icon: "folder", title: "Empty folder", detail: "Nothing to show here. Ignored files are hidden.")
                .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle()).contextMenu { rootMenu }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.rows) { row in
                        let url = URL(fileURLWithPath: row.entry.path)
                        FileRowView(row: row, open: model.isOpen(row.entry), selected: selected == row.id)
                            .onTapGesture(count: 2) { open(row.entry) }
                            .onTapGesture { selected = row.id; if row.entry.isDir { model.toggle(row.entry) } }
                            .onHover { DragOut.shared.setHover("tree:\(row.id)", dragSource(row.entry), entered: $0) }
                            .contextMenu {
                                let e = row.entry
                                if e.isDir {
                                    Button { create(folder: false, in: e.path) } label: { Label("New File", systemImage: "doc.badge.plus") }
                                    Button { create(folder: true, in: e.path) } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                                    Divider()
                                } else {
                                    Button { open(e) } label: { Label("Open", systemImage: "doc.text") }
                                    Button { if remote { model.download(e, to: DownloadFolder.current, open: true) } else { NSWorkspace.shared.open(url) } } label: {
                                        Label(remote ? "Download and Open in Default App" : "Open in Default App", systemImage: "arrow.up.forward.app")
                                    }
                                    Divider()
                                }
                                if remote {
                                    Button { model.download(e, to: DownloadFolder.current, open: false) } label: { Label("Download to \(DownloadFolder.current.lastPathComponent)", systemImage: "arrow.down.circle") }
                                    Button { if let dir = DownloadFolder.choose() { model.download(e, to: dir, open: false) } } label: { Label("Download To…", systemImage: "arrow.down.to.line") }
                                    Divider()
                                } else {
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.writeObjects([url as NSURL])
                                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                                }
                                Button { copyText(e.path) } label: { Label("Copy Path", systemImage: "doc.on.doc") }
                                Button { copyText(model.relativePath(e.path)) } label: { Label("Copy Relative Path", systemImage: "doc.on.doc") }
                                if e.isDir {
                                    Button { app.add(name: e.name, path: e.path, host: host) } label: { Label("Add as Project", systemImage: "folder.badge.plus") }
                                    Button { openInTerminal(e.path) } label: { Label("Open in Terminal", systemImage: "terminal") }
                                    Button { findIn(e.path) } label: { Label("Find in Folder", systemImage: "magnifyingglass") }
                                }
                                if !remote {
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Label("Reveal in Finder", systemImage: "arrow.up.forward.square") }
                                }
                                Divider()
                                Button { rename(e) } label: { Label("Rename", systemImage: "pencil") }
                                Button(role: .destructive) { delete(e) } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                }
                .padding(.vertical, Space.xs)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .contentShape(Rectangle())
            .contextMenu { rootMenu }
        }
    }
}

private struct ResultRow: View {
    let entry: FileEntry
    let dir: String
    let active: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
            Text(entry.name).font(.system(size: 12)).lineLimit(1)
            if !dir.isEmpty {
                Text(dir).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.m).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(active ? Color.accentColor.opacity(0.16) : hover ? Color.primary.opacity(0.06) : .clear).padding(.horizontal, Space.xs))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

private struct FileRowView: View {
    let row: FileRow
    let open: Bool
    let selected: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                .rotationEffect(.degrees(open ? 90 : 0)).opacity(row.entry.isDir ? 1 : 0).frame(width: 10)
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(row.entry.isDir ? Color.accentColor : .secondary).frame(width: 16)
            Text(row.entry.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, 8 + CGFloat(row.depth) * 14).padding(.trailing, 8).padding(.vertical, 3.5)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(selected ? Color.accentColor.opacity(0.16) : hover ? Color.primary.opacity(0.06) : .clear).padding(.horizontal, 4))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: open)
    }

    private var icon: String {
        if row.entry.isDir { return open ? "folder.fill" : "folder" }
        switch (row.entry.name as NSString).pathExtension.lowercased() {
        case "md", "txt": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "svg", "pdf": return "photo"
        case "json", "yml", "yaml", "toml": return "curlybraces"
        case "swift", "rs", "py", "js", "ts", "cjs", "go", "sh": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Where remote downloads go: the last folder the user picked, else ~/Downloads.
@MainActor
enum DownloadFolder {
    private static let key = "downloadFolder"
    static var current: URL {
        if let p = UserDefaults.standard.string(forKey: key), FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
    }
    /// Asks for a folder, starting at the current one, and remembers the choice.
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Download Here"
        panel.directoryURL = current
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        UserDefaults.standard.set(url.path, forKey: key)
        return url
    }
}
