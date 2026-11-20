import AppKit
import SwiftTerm
import SwiftUI

/// Pins each terminal to the bottom edge at a whole number of rows, so the sub-row remainder
/// (up to one cell height) sits above the first row instead of as a band under the status line.
final class TerminalHost: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizesSubviews = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitTerminals()
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        fitTerminals()
    }

    func fitTerminals() {
        for case let v as TerminalView in subviews {
            let rows = max(v.getTerminal().rows, 1)
            let cellH = v.getOptimalFrameSize().height / CGFloat(rows)
            let h = cellH > 0 ? max(cellH, floor(bounds.height / cellH) * cellH) : bounds.height
            let f = NSRect(x: 0, y: 0, width: bounds.width, height: h)
            if v.frame != f { v.frame = f }
        }
    }
}

/// Hosts every session's TerminalView as a permanent subview and only toggles visibility,
/// so switching never detaches (and thereby resizes/clears) a terminal.
struct TerminalStack: NSViewRepresentable {
    @EnvironmentObject var model: AppModel

    /// Remembers what the terminal was last given focus for, so later SwiftUI updates do not take it back.
    final class Coordinator { var focusedFor: Int64? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        TerminalHost()
    }

    func updateNSView(_ container: NSView, context: Context) {
        let sessions = model.sessions
        let selected = model.selectedSessionID
        let dark = model.isDark
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            container.layer?.backgroundColor = nil
            for s in sessions {
                let v = s.term.view
                if v.superview !== container {
                    container.addSubview(v)
                }
                v.isHidden = s.id != selected
            }
            for sub in container.subviews where !sessions.contains(where: { $0.term.view === sub }) {
                sub.removeFromSuperview()
            }
            _ = dark
            // Focus follows a change of the shown session only; every other update (poller ticks, typing in
            // the Find field) must leave the first responder alone or it steals the field's keystrokes.
            let showing = model.showSftp || model.shownFileID != nil ? nil : selected
            if let s = sessions.first(where: { $0.id == showing }), coordinator.focusedFor != showing {
                container.window?.makeFirstResponder(s.term.view)
            }
            coordinator.focusedFor = showing
        }
    }
}
