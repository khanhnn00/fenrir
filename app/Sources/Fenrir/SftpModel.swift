import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum Side: String { case local, remote }
enum SortKey { case name, size, modified }

extension UTType {
    /// Pasteboard type of items dragged between the two panes; declared in Info.plist by build-app.sh.
    static let sftpItems = UTType(exportedAs: "app.fenrir.sftp-items")
}

/// One side of the transfer view: a folder listing with selection, sort and the hidden-files toggle.
@MainActor
final class PaneModel: ObservableObject {
    let side: Side
    @Published var path: String
    @Published private(set) var entries: [SftpEntry] = []
    @Published var error: String?
    @Published var loading = false
    @Published var selection = Set<String>()
    @Published var showHidden = false
    @Published var sortKey = SortKey.name
    @Published var ascending = true
    private var generation = 0

    init(side: Side, path: String) {
        self.side = side
        self.path = path
    }

    /// Folders stay first; hidden entries only when asked for.
    var shown: [SftpEntry] {
        let visible = showHidden ? entries : entries.filter { !$0.name.hasPrefix(".") }
        let cmp: (SftpEntry, SftpEntry) -> Bool
        switch sortKey {
        case .name: cmp = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size: cmp = { $0.size < $1.size }
        case .modified: cmp = { $0.modified < $1.modified }
        }
        let sorted = visible.sorted { ascending ? cmp($0, $1) : cmp($1, $0) }
        return sorted.filter(\.isDir) + sorted.filter { !$0.isDir }
    }

    func sort(by key: SortKey) {
        if sortKey == key { ascending.toggle() } else { sortKey = key; ascending = true }
    }

    func load(_ core: FenrirCore, host: String?) {
        guard !path.isEmpty else { return }
        generation += 1
        let (gen, dir, side) = (generation, path, side)
        loading = true
        Task {
            let result = await Task.detached { () -> Result<[SftpEntry], Error> in
                Result {
                    if side == .remote, let host { return try core.sftpListRemote(host: host, dir: dir) }
                    return try core.sftpListLocal(dir: dir)
                }
            }.value
            guard gen == generation else { return }
            loading = false
            switch result {
            case .success(let e): entries = e; error = nil; selection = selection.filter { p in e.contains { $0.path == p } }
            case .failure(let e): entries = []; error = "\(e)"; selection = []
            }
        }
    }
}

/// State of the file transfer view: both panes, the remote host, and the transfer queue.
@MainActor
final class SftpModel: ObservableObject {
    let core: FenrirCore
    @Published var host: String?
    @Published var transfers: [TransferItem] = []
    /// Set by "apply to all" in the conflict prompt; cleared once nothing is pending.
    @Published var applyAll: ConflictPolicy?
    @Published var errorMessage: String?
    let local = PaneModel(side: .local, path: NSHomeDirectory())
    let remote = PaneModel(side: .remote, path: "")
    private var timer: Timer?
    private var seen: [Int64: TransferState] = [:]

    init(core: FenrirCore) { self.core = core }

    func pane(_ side: Side) -> PaneModel { side == .local ? local : remote }

    /// Starts polling the queue; safe to call again.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        local.load(core, host: nil)
    }

    /// Picks the remote side's host, landing in its home folder.
    func choose(host new: String?) {
        guard new != host || remote.path.isEmpty else { return }
        host = new
        remote.selection = []
        remote.path = ""
        guard let new else { return }
        let core = core
        Task {
            do {
                let home = try await Task.detached { try core.remoteHome(host: new) }.value
                // The user may already have typed a path while the home folder was being fetched.
                guard remote.path.isEmpty, host == new else { return }
                remote.path = home
                remote.load(core, host: new)
            } catch { remote.path = ""; remote.error = "\(error)" }
        }
    }

    func go(_ side: Side, to path: String) {
        let p = pane(side)
        var clean = path
        while clean.count > 1 && clean.hasSuffix("/") { clean.removeLast() }
        p.path = clean.isEmpty ? "/" : clean
        p.selection = []
        p.load(core, host: host)
    }

    func reload(_ side: Side) { pane(side).load(core, host: host) }

    func up(_ side: Side) { go(side, to: (pane(side).path as NSString).deletingLastPathComponent) }

    // MARK: transfers

    /// Queues `paths` from `side` into `dir` (default: the other pane's folder).
    func send(_ paths: [String], from side: Side, into dir: String? = nil) {
        guard let host else { errorMessage = "Choose a host first."; return }
        let target = dir ?? pane(side == .local ? .remote : .local).path
        for p in paths {
            do {
                _ = try core.startTransfer(host: host, direction: side == .local ? .upload : .download,
                                           src: p, dstDir: target, policy: applyAll ?? .ask)
            } catch { errorMessage = "\(error)" }
        }
        poll()
    }

    func resolve(_ item: TransferItem, _ policy: ConflictPolicy, all: Bool) {
        if all { applyAll = policy }
        core.resolveConflict(id: item.id, policy: policy)
    }

    func cancel(_ item: TransferItem) { core.cancelTransfer(id: item.id) }

    func retry(_ item: TransferItem) {
        do { try core.retryTransfer(id: item.id) } catch { errorMessage = "\(error)" }
    }

    func clearFinished() { core.clearFinishedTransfers() }

    var pendingConflict: TransferItem? { applyAll == nil ? transfers.first { $0.state == .conflict } : nil }

    private func poll() {
        let now = core.transfers()
        for t in now {
            if t.state == .conflict, let all = applyAll { core.resolveConflict(id: t.id, policy: all) }
            if t.state == .done, seen[t.id] != .done {
                // The finished item landed in a folder one of the panes may be showing.
                for side in [Side.local, .remote] where pane(side).path == t.dstDir { reload(side) }
            }
            seen[t.id] = t.state
        }
        if applyAll != nil, !now.contains(where: { $0.state == .conflict || $0.state == .queued || $0.state == .running }) { applyAll = nil }
        if now.count != transfers.count || zip(now, transfers).contains(where: { $0.state != $1.state || $0.done != $1.done || $0.speed != $1.speed }) {
            transfers = now
        }
    }

    // MARK: file operations

    func mkdir(_ side: Side, name: String) {
        let dir = pane(side).path
        run(side) { core, h in _ = try core.sftpMkdir(host: h, dir: dir, name: name) }
    }

    func rename(_ side: Side, _ e: SftpEntry, to name: String) {
        run(side) { core, h in _ = try core.sftpRename(host: h, path: e.path, newName: name) }
    }

    func delete(_ side: Side, _ entries: [SftpEntry]) {
        run(side) { core, h in for e in entries { try core.sftpDelete(host: h, path: e.path) } }
    }

    private func run(_ side: Side, _ op: @escaping @Sendable (FenrirCore, String?) throws -> Void) {
        let (core, h) = (core, side == .remote ? host : nil)
        Task {
            do { try await Task.detached { try op(core, h) }.value } catch { errorMessage = "\(error)" }
            reload(side)
        }
    }
}
