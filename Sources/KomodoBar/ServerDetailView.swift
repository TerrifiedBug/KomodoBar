import KomodoBarCore
import SwiftUI

/// Compact server detail shown in the server's submenu: version, then CPU / Mem /
/// Disk each as a current value plus a sparkline of recent samples.
struct ServerDetailView: View {
    let version: String?
    let address: String?
    let stats: SystemStats?
    let cpuHistory: [Double]
    let memHistory: [Double]
    let diskHistory: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let version, !version.isEmpty {
                Text("Komodo Periphery v\(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let address, !address.isEmpty {
                Text(address)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let stats {
                MetricRow(
                    label: "CPU",
                    detail: "\(self.percent(stats.cpuPerc))%",
                    values: self.cpuHistory,
                    tint: self.tint(stats.cpuPerc / 100),
                )
                MetricRow(
                    label: "Mem",
                    detail: "\(self.gb(stats.memUsedGb)) / \(self.gb(stats.memTotalGb)) GB · \(self.percent(stats.memPercent * 100))%",
                    values: self.memHistory,
                    tint: self.tint(stats.memPercent),
                )
                if let disk = stats.primaryDisk {
                    MetricRow(
                        label: "Disk",
                        detail: "\(self.gb(disk.usedGb)) / \(self.gb(disk.totalGb)) GB · \(self.percent(disk.percent * 100))%",
                        values: self.diskHistory,
                        tint: self.tint(disk.percent),
                    )
                }
            } else {
                Text("Stats unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
    }

    private func percent(_ value: Double) -> Int {
        Int(value.rounded())
    }

    private func gb(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func tint(_ fraction: Double) -> Color {
        fraction > 0.9 ? .red : (fraction > 0.75 ? .orange : .green)
    }
}

/// One metric: label + current value on top, full-width sparkline below.
private struct MetricRow: View {
    let label: String
    let detail: String
    let values: [Double]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(self.label).font(.callout).bold()
                Spacer()
                Text(self.detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Sparkline(values: self.values, tint: self.tint).frame(height: 22)
        }
    }
}

/// Minimal line sparkline scaled to its own min/max, no axes.
/// ponytail: built from live poll samples; for true history swap in
/// GetHistoricalServerStats.
private struct Sparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            if self.values.count > 1 {
                let lo = self.values.min() ?? 0
                let hi = self.values.max() ?? 1
                let span = max(hi - lo, 1)
                let stepX = geo.size.width / CGFloat(self.values.count - 1)
                Path { path in
                    for (index, value) in self.values.enumerated() {
                        let point = CGPoint(
                            x: CGFloat(index) * stepX,
                            y: geo.size.height * (1 - CGFloat((value - lo) / span)),
                        )
                        if index == 0 {
                            path.move(to: point)
                        } else {
                            path.addLine(to: point)
                        }
                    }
                }
                .stroke(self.tint, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            } else {
                // Single sample so far: flat baseline so the row isn't empty.
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                    path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
                }
                .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
            }
        }
    }
}
