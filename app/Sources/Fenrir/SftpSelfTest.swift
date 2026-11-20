import AppKit
import Foundation
import UniformTypeIdentifiers

/// `FENRIR_SELFTEST=sftp`: drives the transfer view against one real host (`FENRIR_MACHINE_HOST`, default
/// example-host) inside a throwaway folder it creates under the host's home and removes at the end.
/// Uploads a file and a folder, hits a name conflict, starts and cancels a large upload, downloads both
/// back, compares sha256 on both sides, renames and deletes inside the folder. Needs FENRIR_SHOTS_DIR.
@MainActor
enum SftpSelfTest {
    private static let env = ProcessInfo.processInfo.environment
    static var host: String { env["FENRIR_MACHINE_HOST"] ?? "example-host" }

    static func ssh(_ cmd: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--", host, cmd]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try? p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func local(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// sha256 of every file under `dir`, relative path first, sorted; same shape on both sides.
    static func localSums(_ dir: String) -> String {
        local("/bin/sh", ["-c", "cd '\(dir)' && find . -type f | sort | while read f; do shasum -a 256 \"$f\"; done"])
            .split(separator: "\n").map { $0.split(separator: " ", maxSplits: 1).map(String.init) }
            .map { "\($0[0])  \($0[1].trimmingCharacters(in: .whitespaces))" }.joined(separator: "\n")
    }

    static func remoteSums(_ dir: String) -> String {
        ssh("cd '\(dir)' && find . -type f | sort | while read f; do sha256sum \"$f\"; done")
    }

    private static func waitFinal(_ model: AppModel, _ ids: [Int64], timeout: Double = 120) async -> [TransferItem] {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let items = model.core.transfers().filter { ids.contains($0.id) }
            if items.count == ids.count, items.allSatisfy({ $0.state.isFinal }) { return items }
            await SelfTest.pause(0.3)
        }
        return model.core.transfers().filter { ids.contains($0.id) }
    }

    private static func describe(_ t: TransferItem) -> String {
        "\(t.direction == .upload ? "up" : "down") \(t.name) state=\(t.state) \(t.done)/\(t.total) dst=\(t.dst) \(t.error)"
    }

    static func run(_ model: AppModel) async {
        let shots = env["FENRIR_SHOTS_DIR"] ?? NSTemporaryDirectory() + "fenrir-shots"
        try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
        let core = model.core, sftp = model.sftp
        let stamp = Int(Date().timeIntervalSince1970)
        do {
            let home = try core.testMachine(host: host)
            try model.addMachine(name: "", host: host)
            guard let machine = model.machines.first(where: { $0.host == host }) else { return }
            // Remote scratch folder: everything below happens inside it.
            let box = "fenrir-sftp-test-\(stamp)"
            let remoteDir = try core.sftpMkdir(host: host, dir: home, name: box)
            precondition(remoteDir == "\(home)/\(box)" && remoteDir.contains("fenrir-sftp-test-"))
            SelfTest.log("remote scratch folder \(remoteDir)")

            // Local fixtures.
            let fx = SelfTest.tempDir("fenrir-sftp-\(stamp)")
            let src = fx + "/outbox", back = fx + "/back"
            try FileManager.default.createDirectory(atPath: src + "/project files/sub dir", withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: back, withIntermediateDirectories: true)
            _ = local("/bin/sh", ["-c", "head -c 3000000 /dev/urandom > '\(src)/photo sample.bin'; echo 'hello fenrir' > '\(src)/notes.txt'; " +
                "head -c 700000 /dev/urandom > '\(src)/project files/data.bin'; echo 'x' > '\(src)/project files/sub dir/it'\\''s.txt'; : > '\(src)/project files/empty'; " +
                "head -c 150000000 /dev/urandom > '\(src)/big upload.bin'"])

            model.newTab()
            model.openSftp(for: machine)
            sftp.start()
            for _ in 0..<100 where sftp.remote.path.isEmpty { await SelfTest.pause(0.1) }
            sftp.local.path = src
            sftp.go(.remote, to: remoteDir)
            sftp.go(.local, to: src)
            await SelfTest.pause(2.5)
            SelfTest.log("panes: local=\(sftp.local.shown.map(\.name)) remote=\(sftp.remote.shown.map(\.name)) host=\(sftp.host ?? "-")")

            // Upload through the drop handler, as a drag from the left pane and as a Finder file drop.
            let drag = NSItemProvider()
            let payload = Data(#"{"side":"local","paths":["\#(src)/project files"]}"#.utf8)
            drag.registerDataRepresentation(forTypeIdentifier: UTType.sftpItems.identifier, visibility: .ownProcess) { $0(payload, nil); return nil }
            _ = sftp.handleDrop([drag], onto: .remote, dir: nil)
            _ = sftp.handleDrop([NSItemProvider(object: URL(fileURLWithPath: src + "/photo sample.bin") as NSURL)], onto: .remote, dir: nil)
            await SelfTest.pause(1)
            let first = core.transfers().map(\.id)
            SelfTest.log("queued \(first.count) transfers via drop")
            let ups = await waitFinal(model, first)
            ups.forEach { SelfTest.log(describe($0)) }
            await SelfTest.pause(1.5)
            SelfTest.log("remote now: \(sftp.remote.shown.map(\.name))")
            Screenshots.snapshot(shots + "/sftp-dual-pane.png")

            // Conflict: same file again, left to the user.
            let seed = try core.startTransfer(host: host, direction: .upload, src: src + "/notes.txt", dstDir: remoteDir, policy: .ask)
            _ = await waitFinal(model, [seed])
            let again = try core.startTransfer(host: host, direction: .upload, src: src + "/notes.txt", dstDir: remoteDir, policy: .ask)
            let notes2 = try core.startTransfer(host: host, direction: .upload, src: src + "/notes.txt", dstDir: remoteDir, policy: .ask)
            await SelfTest.pause(0.5)
            let probe = try core.startTransfer(host: host, direction: .upload, src: src + "/notes.txt", dstDir: remoteDir, policy: .ask)
            await SelfTest.pause(2)
            SelfTest.log("conflict states: \(core.transfers().filter { [again, notes2, probe].contains($0.id) }.map { "\($0.name)=\($0.state)" })")
            Screenshots.snapshot(shots + "/sftp-conflict.png")
            if let c = sftp.pendingConflict { sftp.resolve(c, .rename, all: true) }
            let r = await waitFinal(model, [again, notes2, probe])
            r.forEach { SelfTest.log(describe($0)) }

            // Large upload: snapshot while moving, then cancel and check nothing is left half-written.
            let big = try core.startTransfer(host: host, direction: .upload, src: src + "/big upload.bin", dstDir: remoteDir, policy: .ask)
            var shot = false
            for _ in 0..<200 {
                if let t = core.transfers().first(where: { $0.id == big }), t.state == .running, t.done > 8_000_000 {
                    await SelfTest.pause(0.8)
                    let now = core.transfers().first { $0.id == big }!
                    SelfTest.log("in progress: \(describe(now)) speed=\(now.speed)B/s")
                    Screenshots.snapshot(shots + "/sftp-transfer-progress.png")
                    shot = true
                    break
                }
                await SelfTest.pause(0.1)
            }
            core.cancelTransfer(id: big)
            let cancelled = await waitFinal(model, [big], timeout: 30)
            cancelled.forEach { SelfTest.log("cancel: " + describe($0)) }
            await SelfTest.pause(2)
            SelfTest.log("after cancel, remote big files: [\(ssh("ls -1 '\(remoteDir)' | grep -i big || true"))] snapshotTaken=\(shot)")

            // Download both back and compare checksums.
            let dl = [
                try core.startTransfer(host: host, direction: .download, src: remoteDir + "/photo sample.bin", dstDir: back, policy: .ask),
                try core.startTransfer(host: host, direction: .download, src: remoteDir + "/project files", dstDir: back, policy: .ask),
            ]
            (await waitFinal(model, dl)).forEach { SelfTest.log(describe($0)) }
            let upSums = localSums(src + "/project files"), downSums = localSums(back + "/project files")
            let remoteFolder = remoteSums(remoteDir + "/project files")
            SelfTest.log("folder sums local==remote: \(upSums == remoteFolder) local==downloaded: \(upSums == downSums) (\(upSums.split(separator: "\n").count) files)")
            let a = String(local("/usr/bin/shasum", ["-a", "256", src + "/photo sample.bin"]).split(separator: " ").first ?? "")
            let b = String(local("/usr/bin/shasum", ["-a", "256", back + "/photo sample.bin"]).split(separator: " ").first ?? "")
            let c = ssh("sha256sum '\(remoteDir)/photo sample.bin'").split(separator: " ").first.map(String.init) ?? ""
            SelfTest.log("file sha256 original==remote: \(a == c) original==downloaded: \(a == b)")
            SelfTest.log("sizes: original=\(try FileManager.default.attributesOfItem(atPath: src + "/photo sample.bin")[.size] ?? 0) downloaded=\(try FileManager.default.attributesOfItem(atPath: back + "/photo sample.bin")[.size] ?? 0) remote=\(ssh("stat -c %s '\(remoteDir)/photo sample.bin'"))")

            // Rename and delete inside the scratch folder, through the pane model.
            sftp.go(.remote, to: remoteDir)
            await SelfTest.pause(1.5)
            if let e = sftp.remote.shown.first(where: { $0.name == "notes.txt" }) { sftp.rename(.remote, e, to: "renamed notes.txt") }
            await SelfTest.pause(2)
            SelfTest.log("after rename: \(sftp.remote.shown.map(\.name))")
            let doomed = sftp.remote.shown.filter { $0.name.hasPrefix("notes") || $0.name == "project files" }
            precondition(doomed.allSatisfy { $0.path.hasPrefix(remoteDir + "/") })
            sftp.delete(.remote, doomed)
            await SelfTest.pause(2)
            SelfTest.log("after delete: \(sftp.remote.shown.map(\.name))")
            Screenshots.snapshot(shots + "/sftp-done.png")

            // Remove the scratch folder and the local fixtures.
            precondition(remoteDir.hasPrefix(home + "/fenrir-sftp-test-"))
            try core.sftpDelete(host: host, path: remoteDir)
            SelfTest.log("scratch folder removed: \(ssh("[ -e '\(remoteDir)' ] && echo still-there || echo gone"))")
            try? FileManager.default.removeItem(atPath: fx)
        } catch { SelfTest.log("sftp selftest failed: \(error)") }
    }
}
