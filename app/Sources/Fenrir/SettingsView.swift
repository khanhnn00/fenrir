import AppKit
import SwiftUI

struct SettingsView: View {
    @AppStorage("appearance") private var appearance = Appearance.light.rawValue
    let core: FenrirCore
    let onTheme: () -> Void

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0.rawValue) }
                }.pickerStyle(.segmented)
                    .onChange(of: appearance) { _ in onTheme() }
            }
            Section("Agent notifications") {
                HookStatus()
            }
            Section("Remote machines") {
                RemoteHooks()
            }
        }
        .formStyle(.grouped).frame(width: 520).padding(.vertical, 6)
    }

}

private struct RemoteHooks: View {
    @EnvironmentObject var app: AppModel
    @State private var status: [String: String] = [:]
    @State private var busy: Set<String> = []

    private var hosts: [String] { app.machines.compactMap(\.host) }

    var body: some View {
        if hosts.isEmpty {
            Text("Add a machine to set up hooks on its host.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        ForEach(hosts, id: \.self) { host in
            HStack {
                Image(systemName: "network")
                Text(host).fontWeight(.medium)
                Spacer()
                if busy.contains(host) { ProgressView().controlSize(.small) }
                Button("Check") { check(host) }.disabled(busy.contains(host))
                Button("Install hooks") { install(host) }.disabled(busy.contains(host))
            }
            if let s = status[host] { Text(s).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        if !hosts.isEmpty {
            Text("Install copies the hook script to ~/.fenrir on the host and adds it to ~/.claude/settings.json there, backed up first. Runs only when you press it.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func run(_ host: String, _ work: @escaping @Sendable (FenrirCore) throws -> String) {
        let core = app.core
        busy.insert(host); status[host] = nil
        Task {
            do { status[host] = try await Task.detached { try work(core) }.value }
            catch { status[host] = "\(error)" }
            busy.remove(host)
        }
    }

    private func check(_ host: String) {
        run(host) { core in try core.remoteHooksInstalled(host: host) ? "Hooks are installed" : "Hooks are not installed" }
    }

    private func install(_ host: String) {
        run(host) { core in try core.installRemoteHooks(host: host) }
    }
}

private struct HookStatus: View {
    private var wired: Bool {
        let p = NSHomeDirectory() + "/.claude/settings.json"
        return ((try? String(contentsOfFile: p, encoding: .utf8)) ?? "").contains("fenrir-hook.cjs")
    }
    private var installer: String {
        let repo = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        return "node \(repo.path)/scripts/install-hooks.cjs"
    }

    var body: some View {
        Label(wired ? "Claude Code hooks are wired" : "Claude Code hooks are not wired",
              systemImage: wired ? "checkmark.circle.fill" : "exclamationmark.circle")
            .foregroundStyle(wired ? Theme.idle : Theme.needsInput)
        if !wired {
            Text("Run this once in a terminal; it backs up ~/.claude/settings.json first.").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Text(installer).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(installer, forType: .string)
                }
            }
        }
    }
}
