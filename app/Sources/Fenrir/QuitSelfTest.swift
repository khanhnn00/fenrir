import AppKit
import CryptoKit
import Foundation

/// `FENRIR_SELFTEST=t028` (FENRIR_MACHINE_HOST=<host>): the quit alert with and without unsaved files, then a
/// remote text file and a remote binary opened as tabs (edit + save, sha256 of the download). Only touches
/// /tmp/fenrir-t028-<ts>.{txt,bin} on the host and removes them at the end.
@MainActor
enum QuitSelfTest {
    private static var failed = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failed += 1 }
        SelfTest.log("\(ok ? "PASS" : "FAIL") \(name) \(detail)")
    }

    static func run(_ model: AppModel) async {
        let ts = Int(Date().timeIntervalSince1970)
        let host = SftpSelfTest.host
        let guardian = QuitGuard()

        // Quit alert
        let local = SelfTest.tempDir("fenrir-t028") + "/note.txt"
        try? "one\n".write(toFile: local, atomically: true, encoding: .utf8)
        model.openFile(path: local, host: nil)
        await SelfTest.pause(1)
        check("clean tab quits without asking", { QuitGuard.testAnswer = { _ in -1 }; return guardian.applicationShouldTerminate(NSApp) == .terminateNow }())
        model.shownDoc?.text += "two\n"
        var asked: [String] = []
        QuitGuard.testAnswer = { asked = $0; return 2 }
        let cancel = guardian.applicationShouldTerminate(NSApp)
        check("dirty: alert lists the file, Cancel keeps the app", cancel == .terminateCancel && asked == ["note.txt"], "asked=\(asked)")
        QuitGuard.testAnswer = { _ in 1 }
        check("dirty: Discard quits", guardian.applicationShouldTerminate(NSApp) == .terminateNow)
        QuitGuard.testAnswer = { _ in 0 }
        check("dirty: Save All defers the quit", guardian.applicationShouldTerminate(NSApp) == .terminateLater)
        await SelfTest.pause(1)
        let saved = (try? String(contentsOfFile: local, encoding: .utf8)) ?? ""
        check("Save All wrote the file", saved == "one\ntwo\n" && model.shownDoc?.dirty == false, "disk=\(saved.debugDescription)")
        QuitGuard.testAnswer = nil

        // Remote files
        let txt = "/tmp/fenrir-t028-\(ts).txt", bin = "/tmp/fenrir-t028-\(ts).bin"
        _ = SftpSelfTest.ssh("printf 'alpha\\n' > \(txt); head -c 4096 /dev/urandom > \(bin)")
        let remoteSum = SftpSelfTest.ssh("sha256sum \(bin)").split(separator: " ").first.map(String.init) ?? ""
        model.openFile(path: txt, host: host)
        for _ in 0..<40 where model.shownDoc?.path != txt { await SelfTest.pause(0.5) }
        let doc = model.shownDoc
        check("remote text opens as a tab", doc?.host == host && doc?.kind == .text && doc?.text == "alpha\n", "text=\(doc?.text.debugDescription ?? "nil")")
        doc?.text += "beta\n"
        model.saveShownFile()
        for _ in 0..<40 where doc?.dirty == true && doc?.saveError == nil { await SelfTest.pause(0.5) }
        let remote = SftpSelfTest.ssh("cat \(txt)")
        check("Save changed the host file", remote == "alpha\nbeta" && doc?.dirty == false && doc?.saveError == nil, "host=\(remote.debugDescription) err=\(doc?.saveError ?? "none")")

        model.openFile(path: bin, host: host)
        for _ in 0..<40 where model.shownDoc?.path != bin { await SelfTest.pause(0.5) }
        let b = model.shownDoc
        let localSum = b.flatMap { try? Data(contentsOf: $0.localURL) }.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? ""
        check("remote binary downloaded, sha256 matches the host", b?.path == bin && !remoteSum.isEmpty && localSum == remoteSum, "host=\(remoteSum.prefix(12)) local=\(localSum.prefix(12))")

        _ = SftpSelfTest.ssh("rm -f \(txt) \(bin)")
        check("host files removed", SftpSelfTest.ssh("ls \(txt) \(bin) 2>&1 | grep -c 'No such'") == "2")
        SelfTest.log(failed == 0 ? "ALL PASS" : "FAILED \(failed)")
    }
}
