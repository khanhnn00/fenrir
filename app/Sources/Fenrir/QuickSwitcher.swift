import SwiftUI

/// ⌘K: type to filter sessions and projects, Return to jump.
struct QuickSwitcher: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    private var results: [NavEntry] {
        let q = query.lowercased()
        return model.navEntries(nil).filter { e in
            guard !q.isEmpty else { return true }
            switch e {
            case .session(_, let p), .idle(let p): return p.name.lowercased().contains(q) || p.path.lowercased().contains(q) || (p.host ?? "").lowercased().contains(q)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Jump to project or session", text: $query).textFieldStyle(.plain).font(.system(size: 15))
                    .focused($focused).onSubmit { choose(index) }
            }.padding(14)
            Divider()
            if results.isEmpty {
                Text("No match").foregroundStyle(.secondary).padding(24)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { i, e in
                            row(e, active: i == index).onTapGesture { choose(i) }
                        }
                    }.padding(6)
                }.frame(maxHeight: 300)
            }
        }
        .frame(width: 460)
        .onAppear { focused = true }
        .onChange(of: query) { _ in index = 0 }
        .onKeyPress(.downArrow) { index = min(index + 1, max(results.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
    }

    @ViewBuilder private func row(_ e: NavEntry, active: Bool) -> some View {
        let (p, s): (Project, SessionItem?) = {
            switch e { case .session(let s, let p): return (p, s); case .idle(let p): return (p, nil) }
        }()
        HStack(spacing: 8) {
            Circle().fill(s?.state.color ?? Color.secondary.opacity(0.35)).frame(width: 8, height: 8)
            Text(p.name).font(.system(size: 13, weight: .medium))
            if let s, model.sessions(of: p).count > 1 { Text("#\(s.ordinal)").font(.system(size: 11)).foregroundStyle(.secondary) }
            Text(p.path.abbreviatingHome).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let s, s.unread > 0 { Image(systemName: "bell.fill").foregroundStyle(Theme.needsInput).font(.system(size: 11)) }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(active ? Color.accentColor.opacity(0.18) : .clear))
        .contentShape(Rectangle())
    }

    private func choose(_ i: Int) {
        guard results.indices.contains(i) else { return }
        switch results[i] {
        case .session(let s, _): model.select(sessionID: s.id)
        case .idle(let p): model.open(project: p)
        }
        dismiss()
    }
}
