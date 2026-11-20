import AppKit
import SwiftTerm
import UniformTypeIdentifiers

/// One file or folder that can be dragged out of the window.
struct DragItem {
    let path: String
    let name: String
    let isDir: Bool
}

/// What a row hands over when a drag starts on it: the items (read at drag time, so the current
/// selection counts), where they live (`host` nil = this Mac) and, for the two transfer panes,
/// the payload the other pane's drop handler understands.
struct DragSource {
    let host: String?
    let items: () -> [DragItem]
    var payload: (() -> Data)?
}

/// Starts AppKit drag sessions from SwiftUI rows. Local items go out as plain file URLs; remote
/// items go out as file promises: Finder names the destination, and the download runs through the
/// transfer queue and lands there.
final class DragOut: NSObject, NSDraggingSource, NSFilePromiseProviderDelegate, @unchecked Sendable {
    static let shared = DragOut()
    static let payloadType = NSPasteboard.PasteboardType("app.fenrir.sftp-items")

    private var core: FenrirCore?
    private var hover: (id: String, source: DragSource)?
    private var armed: (origin: NSPoint, source: DragSource)?
    private var monitors: [Any] = []
    private let writer: OperationQueue = {
        let q = OperationQueue()
        q.name = "fenrir.drag-out"
        q.maxConcurrentOperationCount = 8
        return q
    }()
    /// Called when a session starts (self-test hook).
    var onBegin: (([DragItem]) -> Void)?

    /// Must run on the main thread, once.
    func attach(_ core: FenrirCore) {
        self.core = core
        guard monitors.isEmpty else { return }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [self] e in
            // A press on a terminal belongs to its selection, whatever row was last hovered.
            var hit = e.window?.contentView?.hitTest(e.locationInWindow)
            while let h = hit, !(h is TerminalView) { hit = h.superview }
            armed = hit == nil ? hover.map { (e.locationInWindow, $0.source) } : nil
            return e
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [self] e in
            armed = nil
            return e
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [self] e in
            guard let a = armed, hypot(e.locationInWindow.x - a.origin.x, e.locationInWindow.y - a.origin.y) > 5 else { return e }
            armed = nil
            return begin(a.source, with: e) ? nil : e
        } as Any)
    }

    /// Rows call this from `.onHover`; the hovered row is the one a drag starts on.
    func setHover(_ id: String, _ source: DragSource?, entered: Bool) {
        if entered, let source { hover = (id, source) } else if hover?.id == id { hover = nil }
    }

    // MARK: session

    @discardableResult
    private func begin(_ s: DragSource, with event: NSEvent) -> Bool {
        let items = s.items()
        guard !items.isEmpty, let view = event.window?.contentView else { return false }
        let at = view.convert(event.locationInWindow, from: nil)
        var dragging: [NSDraggingItem] = []
        for (i, it) in items.enumerated() {
            let writer: NSPasteboardWriting = s.host == nil ? NSURL(fileURLWithPath: it.path) : promise(for: it, host: s.host!)
            let d = NSDraggingItem(pasteboardWriter: writer)
            let icon = NSWorkspace.shared.icon(for: it.isDir ? .folder : (UTType(filenameExtension: (it.name as NSString).pathExtension) ?? .data))
            d.setDraggingFrame(NSRect(x: at.x - 16 + CGFloat(i) * 4, y: at.y - 16 - CGFloat(i) * 4, width: 32, height: 32), contents: icon)
            dragging.append(d)
        }
        if let payload = s.payload {
            let p = NSPasteboardItem()
            p.setData(payload(), forType: Self.payloadType)
            let d = NSDraggingItem(pasteboardWriter: p)
            d.setDraggingFrame(NSRect(x: at.x, y: at.y, width: 1, height: 1), contents: nil)
            dragging.append(d)
        }
        onBegin?(items)
        view.beginDraggingSession(with: dragging, event: event, source: self)
        return true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : [.copy, .generic]
    }

    // MARK: promises

    func promise(for item: DragItem, host: String) -> NSFilePromiseProvider {
        let type = item.isDir ? UTType.folder : (UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data)
        let p = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
        p.userInfo = ["host": host, "path": item.path, "name": item.name, "isDir": item.isDir]
        return p
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        if ProcessInfo.processInfo.environment["FENRIR_DRAG_DEBUG"] != nil { FileHandle.standardError.write(Data("promise: name requested\n".utf8)) }
        return (provider.userInfo as? [String: Any])?["name"] as? String ?? "download"
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { writer }

    /// Runs on `writer`: queues the download, waits for it, and hands back the finished item at `url`.
    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        if ProcessInfo.processInfo.environment["FENRIR_DRAG_DEBUG"] != nil { FileHandle.standardError.write(Data("promise: write requested \(url.path)\n".utf8)) }
        guard let core, let info = provider.userInfo as? [String: Any],
              let host = info["host"] as? String, let path = info["path"] as? String, let name = info["name"] as? String else {
            return completionHandler(CocoaError(.fileReadUnknown))
        }
        let fm = FileManager.default
        // Finder normally asks for exactly the name we gave; then the queue writes straight into the
        // destination folder. Under another name, fetch into a scratch folder and move it into place.
        let direct = url.lastPathComponent == name
        let scratch = NSTemporaryDirectory() + "fenrir-drag-\(UUID().uuidString)"
        let dir = direct ? url.deletingLastPathComponent().path : scratch
        do {
            if !direct { try fm.createDirectory(atPath: scratch, withIntermediateDirectories: true) }
            let id = try core.startTransfer(host: host, direction: .download, src: path, dstDir: dir, policy: .overwrite)
            let final = try wait(for: id, core: core)
            if !direct {
                try fm.moveItem(atPath: final, toPath: url.path)
                try? fm.removeItem(atPath: scratch)
            }
            completionHandler(nil)
        } catch {
            if !direct { try? fm.removeItem(atPath: scratch) }
            completionHandler(error)
        }
    }

    private func wait(for id: Int64, core: FenrirCore) throws -> String {
        while true {
            if let t = core.transfers().first(where: { $0.id == id }) {
                switch t.state {
                case .done: return t.dst
                case .failed, .cancelled, .skipped:
                    throw NSError(domain: "Fenrir", code: 1, userInfo: [NSLocalizedDescriptionKey: "Download of \(t.name) \(t.state == .failed ? "failed: \(t.error)" : "was cancelled")"])
                default: break
                }
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
    }
}
