import AppKit
import Foundation

/// Opening, showing, saving and closing the files of the active tab.
extension AppModel {
    var activeFiles: [FileDoc] { activeTab.files.compactMap { id in docs.first { $0.id == id } } }
    var shownFileID: UUID? { activeTab.shownFile }
    var shownDoc: FileDoc? { shownFileID.flatMap { id in docs.first { $0.id == id } } }

    func showTerminal() {
        tabs[activeIndex].shownFile = nil
        showSftp = false
        focusTerminal()
    }

    func show(file doc: FileDoc) {
        tabs[activeIndex].shownFile = doc.id
        showSftp = false
    }

    /// Opens `path` (on `host`, or on this Mac) as a tab of the active window tab, or shows it if already open.
    func openFile(path: String, host: String?) {
        if let d = activeFiles.first(where: { $0.path == path && $0.host == host }) { return show(file: d) }
        let core = core
        Task {
            do {
                let (kind, text, url) = try await Task.detached { try Self.load(core: core, path: path, host: host) }.value
                let doc = FileDoc(host: host, path: path, kind: kind, localURL: url, text: text)
                docs.append(doc)
                tabs[activeIndex].files.append(doc.id)
                show(file: doc)
            } catch { errorMessage = "Cannot open \((path as NSString).lastPathComponent): \(error)" }
        }
    }

    nonisolated private static func load(core: FenrirCore, path: String, host: String?) throws -> (FileDoc.Kind, String, URL) {
        let name = (path as NSString).lastPathComponent
        var url = URL(fileURLWithPath: path)
        if let host {
            let dir = NSTemporaryDirectory() + "fenrir-remote/\(host)/\(abs(path.hashValue))"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            url = URL(fileURLWithPath: dir + "/" + name)
            try core.downloadRemoteFile(host: host, path: path, localPath: url.path, maxBytes: 200_000_000)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        let head = size > FileDoc.sizeCap ? Data() : try Data(contentsOf: url)
        let kind = size > FileDoc.sizeCap ? FileDoc.Kind.preview : FileDoc.kind(forName: name, data: head)
        let text = kind == .text ? String(decoding: head, as: UTF8.self) : ""
        return (kind, text, url)
    }

    func saveShownFile() {
        guard let d = shownDoc, d.dirty else { return }
        let core = core
        Task { await d.save(core: core) }
    }

    /// Closes the file tab, asking first when it has unsaved changes.
    func requestClose(file d: FileDoc) {
        if d.dirty {
            let alert = NSAlert()
            alert.messageText = "Save changes to \(d.name)?"
            alert.informativeText = "Your changes are lost if you do not save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                let core = core
                Task { await d.save(core: core); if !d.dirty { close(file: d) } }
                return
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        close(file: d)
    }

    private func close(file d: FileDoc) {
        for i in tabs.indices {
            tabs[i].files.removeAll { $0 == d.id }
            if tabs[i].shownFile == d.id { tabs[i].shownFile = tabs[i].files.last }
        }
        docs.removeAll { $0.id == d.id }
        if shownFileID == nil { focusTerminal() }
    }

    /// Before a window tab drops its files: true when nothing is unsaved or the user discards it.
    func confirmDiscardFiles(inTabAt i: Int) -> Bool {
        let dirty = tabs[i].files.compactMap { id in docs.first { $0.id == id } }.filter(\.dirty)
        if !dirty.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Discard unsaved changes?"
            alert.informativeText = dirty.map(\.name).joined(separator: ", ")
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        let gone = Set(tabs[i].files)
        docs.removeAll { gone.contains($0.id) }
        return true
    }

    /// Called from the poller: asks the shown local file whether it changed on disk.
    func checkShownFile() { shownDoc?.checkDisk() }
}
