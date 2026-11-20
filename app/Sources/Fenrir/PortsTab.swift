import AppKit
import SwiftUI

/// Forwards of one remote host plus the ports listening on it.
@MainActor
final class PortsModel: ObservableObject {
    @Published private(set) var forwards: [PortForward] = []
    @Published private(set) var detected: [ListeningPort] = []
    @Published private(set) var detectFailure: String?
    @Published var error: String?
    let host: String
    private let core: FenrirCore
    private var detectedAt = Date.distantPast
    private var detecting = false

    init(core: FenrirCore, host: String) {
        self.core = core
        self.host = host
    }

    /// Forwards come from the core's memory each tick; the host is asked for listening ports every few seconds.
    func refresh(detect: Bool) async {
        forwards = core.forwardList(host: host)
        guard detect, !detecting, Date().timeIntervalSince(detectedAt) > 6 else { return }
        detecting = true
        let (core, host) = (core, host)
        let result = await Task.detached { Result { try core.forwardDetect(host: host) } }.value
        detecting = false
        detectedAt = Date()
        switch result {
        case .success(let p): detected = p; detectFailure = nil
        case .failure(let e): detectFailure = "\(e)"
        }
    }

    func run() async {
        while !Task.isCancelled {
            await refresh(detect: true)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    func add(remote: UInt16, local: UInt16?) {
        do {
            _ = try core.forwardAdd(host: host, remotePort: remote, localPort: local)
            error = nil
            forwards = core.forwardList(host: host)
        } catch let e { self.error = "\(e)" }
    }

    func stop(_ f: PortForward) {
        do { try core.forwardStop(id: f.id); error = nil } catch let e { self.error = "\(e)" }
        forwards = core.forwardList(host: host)
    }

    func url(_ f: PortForward) -> String { "http://127.0.0.1:\(f.localPort)" }
    func open(_ f: PortForward) { if let u = URL(string: url(f)) { NSWorkspace.shared.open(u) } }
    func copy(_ f: PortForward) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url(f), forType: .string)
    }
    func process(forRemote port: UInt16) -> String { detected.first { $0.port == port }?.process ?? "" }
}

struct PortsTab: View {
    let host: String
    @StateObject private var model: PortsModel
    @State private var remote = ""
    @State private var local = ""

    init(host: String, core: FenrirCore) {
        self.host = host
        _model = StateObject(wrappedValue: PortsModel(core: core, host: host))
    }

    private var unforwarded: [ListeningPort] {
        model.detected.filter { d in !model.forwards.contains { $0.remotePort == d.port } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.m) {
                addForm
                if let e = model.error { Text(e).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                section("Forwarded")
                if model.forwards.isEmpty {
                    Text("Nothing forwarded yet.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(model.forwards, id: \.id) { ForwardRow(model: model, forward: $0) }
                section("Listening on \(host)")
                if let f = model.detectFailure {
                    Text(f).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if unforwarded.isEmpty {
                    Text("No other listening ports.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(unforwarded, id: \.port) { d in
                    HStack(spacing: Space.s) {
                        Text(String(d.port)).font(.system(size: 12, design: .monospaced))
                        Text(d.process).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Forward") { model.add(remote: d.port, local: nil) }.controlSize(.small)
                    }
                }
            }
            .padding(Space.m)
        }
        .task { await model.run() }
    }

    private var addForm: some View {
        HStack(spacing: Space.s) {
            TextField("Remote port", text: $remote).textFieldStyle(.roundedBorder).frame(minWidth: 0)
            TextField("Local port", text: $local).textFieldStyle(.roundedBorder).frame(minWidth: 0)
            Button("Add") {
                guard let r = UInt16(remote.trimmingCharacters(in: .whitespaces)) else { model.error = "Remote port must be a number from 1 to 65535."; return }
                let l = local.trimmingCharacters(in: .whitespaces)
                if !l.isEmpty && UInt16(l) == nil { model.error = "Local port must be a number from 1 to 65535."; return }
                model.add(remote: r, local: UInt16(l))
                if model.error == nil { remote = ""; local = "" }
            }
            .disabled(remote.isEmpty)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.top, Space.xs)
    }
}

private struct ForwardRow: View {
    @ObservedObject var model: PortsModel
    let forward: PortForward

    private var color: Color {
        switch forward.status {
        case .active: return Theme.idle
        case .starting: return Theme.working
        case .reconnecting: return Theme.needsInput
        case .failed: return .red
        }
    }

    private var label: String {
        switch forward.status {
        case .active: return "Active"
        case .starting: return "Connecting"
        case .reconnecting: return "Reconnecting"
        case .failed: return "Failed"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Circle().fill(color).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text("127.0.0.1:\(String(forward.localPort))").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                let proc = model.process(forRemote: forward.remotePort)
                Text(["Remote \(forward.remotePort)", label, proc].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !forward.detail.isEmpty {
                    Text(forward.detail).font(.system(size: 11)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            iconButton("globe", "Open in browser") { model.open(forward) }
            iconButton("doc.on.doc", "Copy local URL") { model.copy(forward) }
            iconButton("xmark", "Stop forwarding") { model.stop(forward) }
        }
    }

    private func iconButton(_ name: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.system(size: 11)).frame(width: 18, height: 18) }
            .buttonStyle(.borderless).help(help)
    }
}
