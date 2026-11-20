import AppKit
import SwiftUI

@main
struct FenrirApp: App {
    @NSApplicationDelegateAdaptor(QuitGuard.self) private var quitGuard
    @StateObject private var model = AppModel()
    @AppStorage("appearance") private var appearance = Appearance.light.rawValue

    init() {
        // A bare executable (no .app bundle) needs this to get a window and focus.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Fenrir") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1040, minHeight: 600)
                .preferredColorScheme((Appearance(rawValue: appearance) ?? .light).colorScheme)
                .task {
                    Notifier.shared.setup()
                    QuitGuard.model = model
                    model.startPolling()
                    model.restoreSessions()
                    model.restoreForwards()
                    DragOut.shared.attach(model.core)
                    SelfTest.runIfRequested(model)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { model.newTab() }.keyboardShortcut("n")
                Button("Close Tab") { model.closeTab(model.activeTabID) }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                Button(model.shownDoc == nil ? "Close Session" : "Close File") {
                    if let d = model.shownDoc { model.requestClose(file: d) } else if let s = model.selectedSession { model.requestClose(s) }
                }
                .keyboardShortcut("w").disabled(model.shownDoc == nil && model.selectedSession == nil)
                Divider()
                Button("New Session") { if let p = model.activeProject { model.newSession(in: p) } }
                    .keyboardShortcut("t").disabled(model.activeProject == nil)
                Button("Add Project…") { model.showAddProject = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift]).disabled(model.activeMachine == nil)
                Button("Add Machine…") { if model.activeMachine != nil { model.newTab() }; model.showAddMachine = true }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.saveShownFile() }.keyboardShortcut("s").disabled(model.shownDoc?.dirty != true)
            }
            CommandGroup(replacing: .printItem) {
                Button("Find Files") { model.focusFind() }.keyboardShortcut("p").disabled(model.activeProject == nil)
            }
            CommandGroup(after: .sidebar) {
                Button(model.showSidebar ? "Hide Sidebar" : "Show Sidebar") { model.showSidebar.toggle() }
                    .keyboardShortcut("\\")
                Button("Toggle Sidebar") { model.showSidebar.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                Button(model.showPanel ? "Hide Files Panel" : "Show Files Panel") { model.showPanel.toggle() }
                    .keyboardShortcut("\\", modifiers: [.command, .option])
            }
            CommandMenu("Go") {
                Button("Quick Switch…") { model.showQuickSwitcher = true }.keyboardShortcut("k")
                    .disabled(model.activeMachine == nil)
                Button("Previous Tab") { model.switchTab(by: -1) }.keyboardShortcut("[", modifiers: [.command, .shift])
                Button("Next Tab") { model.switchTab(by: 1) }.keyboardShortcut("]", modifiers: [.command, .shift])
                Divider()
                ForEach(1...9, id: \.self) { i in
                    Button("Project \(i)") { model.openProject(at: i - 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i)")), modifiers: .command)
                }
            }
        }
        Settings {
            SettingsView(core: model.core) { DispatchQueue.main.async { model.applyTheme() } }
                .environmentObject(model)
                .preferredColorScheme((Appearance(rawValue: appearance) ?? .light).colorScheme)
        }
    }
}
