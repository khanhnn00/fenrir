import AppKit
import Foundation

/// A file opened in a tab of the main area: editable text, or a Quick Look preview (view-only).
@MainActor
final class FileDoc: ObservableObject, Identifiable {
    enum Kind { case text, preview }

    let id = UUID()
    let host: String?
    let path: String
    let kind: Kind
    /// Preview: the file on this Mac (a temp copy for remote files). Text: where the last load came from.
    let localURL: URL
    @Published var text: String
    @Published private(set) var savedText: String
    /// The file changed on disk since it was loaded or saved.
    @Published var changedOnDisk = false
    @Published var saveError: String?
    private var diskDate: Date?

    var name: String { (path as NSString).lastPathComponent }
    var dirty: Bool { kind == .text && text != savedText }

    nonisolated static let sizeCap = 5_000_000
    nonisolated private static let previewExts: Set<String> = [
        "pdf", "png", "jpg", "jpeg", "gif", "heic", "tiff", "bmp", "webp", "xlsx", "xls", "docx", "doc", "pptx", "ppt",
        "key", "numbers", "pages", "rtf", "rtfd", "mov", "mp4", "m4v", "mp3", "m4a", "wav", "zip", "ico", "icns"
    ]

    init(host: String?, path: String, kind: Kind, localURL: URL, text: String = "") {
        self.host = host
        self.path = path
        self.kind = kind
        self.localURL = localURL
        self.text = text
        savedText = text
        diskDate = FileDoc.modified(localURL)
    }

    static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Decides text or preview from the extension, then the bytes: UTF-8 without NUL under the size cap is text.
    nonisolated static func kind(forName name: String, data: Data) -> Kind {
        let ext = (name as NSString).pathExtension.lowercased()
        if previewExts.contains(ext) { return .preview }
        guard data.count <= sizeCap, !data.contains(0), String(data: data, encoding: .utf8) != nil else { return .preview }
        return .text
    }

    /// Writes the buffer back: to the file for local ones, over ssh for remote ones.
    func save(core: FenrirCore) async {
        let data = Data(text.utf8)
        do {
            if let host {
                let (path, core) = (path, core)
                try await Task.detached { try core.writeRemoteFile(host: host, path: path, data: data) }.value
            } else {
                try data.write(to: localURL, options: .atomic)
            }
            savedText = text
            saveError = nil
            changedOnDisk = false
            if host == nil { diskDate = FileDoc.modified(localURL) }
        } catch { saveError = "\(error)" }
    }

    /// Local files only: flags a change made by another program since the last load or save.
    func checkDisk() {
        guard host == nil, kind == .text, let now = FileDoc.modified(localURL), let was = diskDate, now > was else { return }
        diskDate = now
        if let s = try? String(contentsOf: localURL, encoding: .utf8), s != savedText { changedOnDisk = true }
    }

    func reload() {
        guard host == nil, let s = try? String(contentsOf: localURL, encoding: .utf8) else { return }
        text = s
        savedText = s
        changedOnDisk = false
        diskDate = FileDoc.modified(localURL)
    }
}
