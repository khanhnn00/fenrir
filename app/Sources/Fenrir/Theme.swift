import AppKit
import SwiftUI
import SwiftTerm

/// Light is the default; dark only when the user picks it (or System).
enum Appearance: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
    static var stored: Appearance {
        Appearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .light
    }
}

/// Spacing scale for the window chrome.
enum Space {
    static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16
    /// Height of the band holding the traffic lights, the toggle buttons and the tabs.
    static let bar: CGFloat = 38
}

/// The system sidebar material behind the left column.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar; v.blendingMode = .behindWindow; v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

enum Theme {
    static let working = Color(red: 0.18, green: 0.46, blue: 0.95)
    static let idle = Color(red: 0.20, green: 0.70, blue: 0.40)
    static let needsInput = Color(red: 0.96, green: 0.58, blue: 0.10)
    static let agents = Color(red: 0.62, green: 0.40, blue: 0.92)
    static let exited = SwiftUI.Color.gray

    private static func c(_ hex: UInt32) -> SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16((hex >> 16) & 0xff) * 257, green: UInt16((hex >> 8) & 0xff) * 257, blue: UInt16(hex & 0xff) * 257)
    }
    private static func ns(_ hex: UInt32) -> NSColor {
        NSColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }

    private static let lightPalette: [UInt32] = [
        0x24292f, 0xcf222e, 0x116329, 0x7d4e00, 0x0969da, 0x8250df, 0x1b7c83, 0x6e7781,
        0x57606a, 0xa40e26, 0x1a7f37, 0x9a6700, 0x218bff, 0xa475f9, 0x3192aa, 0x8c959f,
    ]
    private static let darkPalette: [UInt32] = [
        0x484f58, 0xff7b72, 0x3fb950, 0xd29922, 0x58a6ff, 0xbc8cff, 0x39c5cf, 0xb1bac4,
        0x6e7681, 0xffa198, 0x56d364, 0xe3b341, 0x79c0ff, 0xd2a8ff, 0x56d4dd, 0xf0f6fc,
    ]

    @MainActor static func apply(to view: TerminalView, dark: Bool) {
        view.getTerminal().installPalette(colors: (dark ? darkPalette : lightPalette).map(c))
        view.nativeBackgroundColor = ns(dark ? 0x161b22 : 0xfbfbfc)
        view.nativeForegroundColor = ns(dark ? 0xe6edf3 : 0x24292f)
        view.layer?.backgroundColor = ns(dark ? 0x161b22 : 0xfbfbfc).cgColor
        view.caretColor = ns(dark ? 0x58a6ff : 0x0969da)
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.needsDisplay = true
    }
}

extension String {
    /// `/Users/me/work/x` -> `~/work/x`
    var abbreviatingHome: String { (self as NSString).abbreviatingWithTildeInPath }
}
