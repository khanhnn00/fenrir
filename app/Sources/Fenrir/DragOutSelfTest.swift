import AppKit
import Foundation

/// `FENRIR_SELFTEST=dragout`: fulfils file promises for a remote file and folder as the system does on a drop
/// (each promise gets a destination url in a Finder-like drop folder), compares sha256 with the host, then starts a real AppKit drag
/// session from synthetic mouse events. Uses a throwaway `fenrir-dragout-test-<ts>` folder under the
/// host's home (`FENRIR_MACHINE_HOST`, default example-host) and removes it at the end.
@MainActor
enum DragOutSelfTest {
    static func run(_ model: AppModel) async {
        let core = model.core
        let host = SftpSelfTest.host
        let stamp = Int(Date().timeIntervalSince1970)
        do {
            let home = try core.testMachine(host: host)
            let box = "fenrir-dragout-test-\(stamp)"
            let remoteDir = try core.sftpMkdir(host: host, dir: home, name: box)
            precondition(remoteDir == "\(home)/\(box)")
            DragOut.shared.attach(core)
            _ = SftpSelfTest.ssh("cd '\(remoteDir)' && head -c 3000000 /dev/urandom > 'photo sample.bin' && mkdir -p 'project files/sub dir' && " +
                "echo hello > 'project files/a.txt' && head -c 200000 /dev/urandom > 'project files/sub dir/b bin' && echo x > 'project files/c d.txt'")
            let fx = SelfTest.tempDir("fenrir-dragout-\(stamp)")
            let items = [DragItem(path: remoteDir + "/photo sample.bin", name: "photo sample.bin", isDir: false),
                         DragItem(path: remoteDir + "/project files", name: "project files", isDir: true)]

            // What the system does on a drop: it hands each promise a destination url inside the folder the user dropped on.
            let dest = fx + "/finder-drop"
            try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
            for it in items {
                let p = DragOut.shared.promise(for: it, host: host)
                SelfTest.log("promise \(it.name): file name asked = \(DragOut.shared.filePromiseProvider(p, fileNameForType: it.isDir ? "public.folder" : "public.data"))")
                let done = Locked<String?>(nil), fin = Locked(false)
                DragOut.shared.filePromiseProvider(p, writePromiseTo: URL(fileURLWithPath: dest + "/" + it.name)) { e in done.set(e.map { "\($0)" }); fin.set(true) }
                for _ in 0..<300 where !fin.value { await SelfTest.pause(0.2) }
                SelfTest.log("fulfilled \(it.name): finished=\(fin.value) error=\(done.value ?? "none")")
            }
            let sums = SftpSelfTest.localSums(dest + "/project files")
            SelfTest.log("folder sums remote==dropped: \(sums == SftpSelfTest.remoteSums(remoteDir + "/project files")) (\(sums.split(separator: "\n").count) files)")
            let a = SftpSelfTest.local("/usr/bin/shasum", ["-a", "256", dest + "/photo sample.bin"]).split(separator: " ").first.map(String.init) ?? "-"
            let b = SftpSelfTest.ssh("sha256sum '\(remoteDir)/photo sample.bin'").split(separator: " ").first.map(String.init) ?? "--"
            SelfTest.log("file sha256 remote==dropped: \(a == b)")
            let leftovers = SftpSelfTest.local("/bin/sh", ["-c", "ls -a '\(dest)'"]).split(separator: "\n").map(String.init)
            SelfTest.log("drop folder content: \(leftovers.filter { $0 != "." && $0 != ".." })")

            // Same promise written under another name (Finder renaming on a clash): scratch download, then move.
            let renamed = URL(fileURLWithPath: dest + "/photo sample 2.bin")
            let p = DragOut.shared.promise(for: items[0], host: host)
            let done = Locked<String?>(nil), fin = Locked(false)
            DragOut.shared.filePromiseProvider(p, writePromiseTo: renamed) { e in done.set(e.map { "\($0)" }); fin.set(true) }
            for _ in 0..<300 where !fin.value { await SelfTest.pause(0.2) }
            let c = SftpSelfTest.local("/usr/bin/shasum", ["-a", "256", renamed.path]).split(separator: " ").first.map(String.init) ?? "-"
            SelfTest.log("renamed promise: error=\(done.value ?? "none") sha256 remote==dropped: \(c == b)")

            await beginSession(model, host: host, items: items)

            precondition(remoteDir.hasPrefix(home + "/fenrir-dragout-test-"))
            try core.sftpDelete(host: host, path: remoteDir)
            SelfTest.log("scratch folder removed: \(SftpSelfTest.ssh("[ -e '\(remoteDir)' ] && echo still-there || echo gone"))")
            try? FileManager.default.removeItem(atPath: fx)
        } catch { SelfTest.log("dragout selftest failed: \(error)") }
    }

    /// A row under the mouse, a press and a 30 pt drag: the monitor must open a dragging session.
    private static func beginSession(_ model: AppModel, host: String, items: [DragItem]) async {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { SelfTest.log("session: no window"); return }
        let began = Locked<[String]>([])
        DragOut.shared.onBegin = { its in began.set(its.map(\.name)) }
        for (label, h) in [("remote promise", host), ("local url", nil as String?)] {
            began.set([])
            DragOut.shared.setHover("test", DragSource(host: h, items: { items }, payload: { Data("{}".utf8) }), entered: true)
            func ev(_ t: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
                NSEvent.mouseEvent(with: t, location: NSPoint(x: x, y: 200), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            NSApp.sendEvent(ev(.leftMouseDown, 300))
            NSApp.sendEvent(ev(.leftMouseDragged, 330))
            await SelfTest.pause(0.5)
            SelfTest.log("session (\(label)): began=\(!began.value.isEmpty) items=\(began.value)")
            NSApp.sendEvent(ev(.leftMouseUp, 330))
            await SelfTest.pause(0.5)
        }
        DragOut.shared.setHover("test", nil, entered: false)
    }
}

/// Small lock-protected box for values written from promise callbacks.
final class Locked<T>: @unchecked Sendable {
    private var v: T
    private let l = NSLock()
    init(_ v: T) { self.v = v }
    var value: T { l.lock(); defer { l.unlock() }; return v }
    func set(_ n: T) { l.lock(); v = n; l.unlock() }
    func mutate(_ f: (inout T) -> Void) { l.lock(); f(&v); l.unlock() }
}
