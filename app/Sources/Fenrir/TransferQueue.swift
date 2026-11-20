import SwiftUI

private func bytes(_ n: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

/// The queue under the panes: progress, speed, cancel and retry per item.
struct TransferQueue: View {
    @ObservedObject var sftp: SftpModel
    @Binding var open: Bool

    private var active: Int { sftp.transfers.filter { !$0.state.isFinal }.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { open.toggle() } label: {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .bold)).frame(width: 14)
                }.buttonStyle(.plain)
                Text("Transfers").font(.system(size: 12, weight: .semibold))
                Text(active > 0 ? "\(active) active" : sftp.transfers.isEmpty ? "nothing queued" : "all finished")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Clear Finished") { sftp.clearFinished() }.controlSize(.small)
                    .disabled(!sftp.transfers.contains { $0.state.isFinal })
            }
            .padding(.horizontal, Space.m).frame(height: 28)
            if open {
                Divider()
                if sftp.transfers.isEmpty {
                    Text("Drag files or folders between the panes to transfer them.").font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 56)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(sftp.transfers.reversed(), id: \.id) { TransferRow(sftp: sftp, item: $0) }
                        }
                    }.frame(height: min(CGFloat(sftp.transfers.count) * 46 + 4, 190))
                }
            }
        }
    }
}

extension TransferState {
    var isFinal: Bool { self == .done || self == .skipped || self == .failed || self == .cancelled }
}

private struct TransferRow: View {
    @ObservedObject var sftp: SftpModel
    let item: TransferItem

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: item.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 18)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text("\(item.direction == .upload ? "to" : "from") \(item.host)")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                if item.state == .running || item.state == .queued {
                    ProgressView(value: item.total == 0 ? 0 : Double(item.done), total: Double(max(item.total, 1))).controlSize(.small)
                }
                Text(status).font(.system(size: 11)).foregroundStyle(item.state == .failed ? Color.red : .secondary).lineLimit(1)
                    .help(item.error)
            }
            Spacer(minLength: 0)
            if item.state == .failed || item.state == .cancelled {
                BarButton(icon: "arrow.clockwise", help: "Retry") { sftp.retry(item) }
            }
            if !item.state.isFinal {
                BarButton(icon: "xmark.circle", help: "Cancel") { sftp.cancel(item) }
            }
        }
        .padding(.horizontal, Space.m).frame(height: 46)
    }

    private var tint: Color {
        switch item.state {
        case .done: return Theme.idle
        case .failed: return .red
        case .cancelled, .skipped: return .gray
        case .conflict: return Theme.needsInput
        default: return Theme.working
        }
    }

    private var status: String {
        switch item.state {
        case .queued: return "Waiting"
        case .conflict: return "Already exists, waiting for your choice"
        case .running:
            let pct = item.total == 0 ? "" : " \(Int(Double(item.done) / Double(item.total) * 100))%"
            return "\(bytes(item.done)) of \(bytes(item.total))\(pct) · \(bytes(item.speed))/s"
        case .done: return "Done · \(bytes(item.total))\(item.dst.isEmpty ? "" : " · \(item.dst)")"
        case .skipped: return "Skipped, it already exists"
        case .cancelled: return "Cancelled"
        case .failed: return item.error
        }
    }
}
