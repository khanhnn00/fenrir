import AppKit

/// ⌘Q and the app menu's Quit: with unsaved file tabs, asks Save All / Discard / Cancel first.
final class QuitGuard: NSObject, NSApplicationDelegate {
    @MainActor static weak var model: AppModel?
    /// Selftest hook: answers the alert without showing it (0 = Save All, 1 = Discard, 2 = Cancel).
    @MainActor static var testAnswer: (([String]) -> Int)?

    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model else { return .terminateNow }
        let dirty = model.docs.filter(\.dirty)
        if dirty.isEmpty { return .terminateNow }
        let names = dirty.map(\.name)
        let answer: Int
        if let t = Self.testAnswer { answer = t(names) } else {
            let alert = NSAlert()
            alert.messageText = "You have unsaved changes"
            alert.informativeText = "Unsaved files: " + names.joined(separator: ", ")
            alert.addButton(withTitle: "Save All")
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            answer = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        }
        switch answer {
        case 0:
            let core = model.core
            Task { @MainActor in
                for d in dirty { await d.save(core: core) }
                if let bad = dirty.first(where: { $0.dirty }) {
                    model.errorMessage = "Cannot save \(bad.name); quit cancelled"
                    NSApp.reply(toApplicationShouldTerminate: false)
                } else {
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            }
            return .terminateLater
        case 1: return .terminateNow
        default: return .terminateCancel
        }
    }
}
