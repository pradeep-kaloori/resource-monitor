import SwiftUI
import Charts

@main
struct ResourceMonitorApp: App {
    @StateObject private var monitor = Monitor()
    var body: some Scene {
        WindowGroup("Resource Monitor") {
            DashboardView()
                .environmentObject(monitor)
                .frame(minWidth: 900, minHeight: 700)
                .onAppear { monitor.start() }
        }
        MenuBarExtra {
            MenuBarView().environmentObject(monitor)
        } label: {
            MenuBarLabel().environmentObject(monitor)
        }
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject var m: Monitor
    var body: some View {
        Text(String(format: "CPU %.0f%%  MEM %.0f%%", m.samples.last?.cpu ?? 0, m.samples.last?.memUsed ?? 0))
    }
}

struct MenuBarView: View {
    @EnvironmentObject var m: Monitor
    var body: some View {
        Text(String(format: "CPU %.0f%%", m.samples.last?.cpu ?? 0))
        Text(String(format: "Memory %.1f / %.0f GB", m.mem.app + m.mem.wired + m.mem.compressed, m.mem.total))
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
}

func color(for v: Double) -> Color { v < 60 ? .green : v < 85 ? .orange : .red }

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

struct RingGauge: View {
    let value: Double
    let label: String
    let detail: String
    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 14)
            Circle().trim(from: 0, to: min(value, 100) / 100)
                .stroke(color(for: value), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: value)
            VStack(spacing: 2) {
                Text(String(format: "%.0f%%", value)).font(.system(size: 30, weight: .bold, design: .rounded))
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 140, height: 140)
        .padding(6)
    }
}

struct DashboardView: View {
    @EnvironmentObject var m: Monitor

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                topRow
                HStack(alignment: .top, spacing: 14) { cpuChart; memChart }
                HStack(alignment: .top, spacing: 14) { coresCard; memBreakdown }
                HStack(alignment: .top, spacing: 14) { netChart; diskIOChart }
                HStack(alignment: .top, spacing: 14) { diskCapacity; topApps }
                tipsCard
            }
            .padding(16)
        }
    }

    var cpuNow: Double { m.samples.last?.cpu ?? 0 }
    var memNow: Double { m.samples.last?.memUsed ?? 0 }

    var topRow: some View {
        HStack(spacing: 14) {
            Card(title: "CPU") {
                HStack { Spacer(); RingGauge(value: cpuNow, label: "CPU", detail: "\(m.cores) cores"); Spacer() }
            }
            Card(title: "Memory") {
                HStack {
                    Spacer()
                    RingGauge(value: memNow, label: "Memory",
                              detail: String(format: "%.1f / %.0f GB", m.mem.app + m.mem.wired + m.mem.compressed, m.mem.total))
                    Spacer()
                }
            }
            Card(title: "Disk (/)") {
                let pct = m.diskTotalGB > 0 ? m.diskUsedGB / m.diskTotalGB * 100 : 0
                HStack {
                    Spacer()
                    RingGauge(value: pct, label: "Disk", detail: String(format: "%.0f / %.0f GB", m.diskUsedGB, m.diskTotalGB))
                    Spacer()
                }
            }
            Card(title: "Memory pressure") {
                let (txt, c): (String, Color) = m.mem.pressure >= 4 ? ("Critical", .red) : m.mem.pressure == 2 ? ("Warning", .orange) : ("Normal", .green)
                VStack(spacing: 8) {
                    Circle().fill(c).frame(width: 60, height: 60)
                    Text(txt).font(.title3.bold())
                    Text(String(format: "Swap: %.1f GB", m.mem.swapUsed)).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 140)
            }
        }
    }

    var cpuChart: some View {
        Card(title: String(format: "CPU history (avg %.0f%%)", m.cpuHistoryAvg)) {
            Chart(m.samples) {
                AreaMark(x: .value("t", $0.time), y: .value("CPU", $0.cpu)).foregroundStyle(.blue.opacity(0.25)).interpolationMethod(.monotone)
                LineMark(x: .value("t", $0.time), y: .value("CPU", $0.cpu)).foregroundStyle(.blue).interpolationMethod(.monotone)
            }
            .chartYScale(domain: 0...100)
            .frame(height: 160)
        }
    }

    var memChart: some View {
        Card(title: "Memory history") {
            Chart(m.samples) {
                AreaMark(x: .value("t", $0.time), y: .value("Mem", $0.memUsed)).foregroundStyle(.purple.opacity(0.25)).interpolationMethod(.monotone)
                LineMark(x: .value("t", $0.time), y: .value("Mem", $0.memUsed)).foregroundStyle(.purple).interpolationMethod(.monotone)
            }
            .chartYScale(domain: 0...100)
            .frame(height: 160)
        }
    }

    var coresCard: some View {
        Card(title: "Per-core load") {
            Chart(Array(m.perCore.enumerated()), id: \.offset) { i, v in
                BarMark(x: .value("Core", "\(i)"), y: .value("Load", v)).foregroundStyle(color(for: v))
            }
            .chartYScale(domain: 0...100)
            .frame(height: 150)
        }
    }

    var memBreakdown: some View {
        let parts: [(String, Double, Color)] = [
            ("App", m.mem.app, .blue), ("Wired", m.mem.wired, .orange), ("Compressed", m.mem.compressed, .red),
            ("Cached", m.mem.cached, .teal), ("Free", m.mem.free, .gray.opacity(0.4))
        ]
        return Card(title: "Memory breakdown (GB)") {
            HStack {
                Chart(parts, id: \.0) { p in
                    SectorMark(angle: .value("GB", p.1), innerRadius: .ratio(0.6), angularInset: 1).foregroundStyle(p.2)
                }
                .frame(width: 150, height: 150)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(parts, id: \.0) { p in
                        HStack { Circle().fill(p.2).frame(width: 9, height: 9); Text(p.0); Spacer(); Text(String(format: "%.1f", p.1)).monospacedDigit() }
                    }
                }
            }
        }
    }

    var netChart: some View {
        Card(title: "Network  ↓ \(rate(m.samples.last?.netDown ?? 0))  ↑ \(rate(m.samples.last?.netUp ?? 0))") {
            Chart {
                ForEach(m.samples) {
                    LineMark(x: .value("t", $0.time), y: .value("B/s", $0.netDown), series: .value("d", "Down")).foregroundStyle(.green)
                    LineMark(x: .value("t", $0.time), y: .value("B/s", $0.netUp), series: .value("d", "Up")).foregroundStyle(.pink)
                }
            }
            .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(rate(d)) } } } }
            .frame(height: 150)
        }
    }

    var diskIOChart: some View {
        Card(title: "Disk I/O  read \(rate(m.samples.last?.diskRead ?? 0))  write \(rate(m.samples.last?.diskWrite ?? 0))") {
            Chart {
                ForEach(m.samples) {
                    LineMark(x: .value("t", $0.time), y: .value("B/s", $0.diskRead), series: .value("d", "Read")).foregroundStyle(.cyan)
                    LineMark(x: .value("t", $0.time), y: .value("B/s", $0.diskWrite), series: .value("d", "Write")).foregroundStyle(.orange)
                }
            }
            .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(rate(d)) } } } }
            .frame(height: 150)
        }
    }

    var diskCapacity: some View {
        let parts: [(String, Double, Color)] = [("Used", m.diskUsedGB, .blue), ("Free", m.diskFreeGB, .gray.opacity(0.4))]
        return Card(title: "Disk capacity (GB)") {
            HStack {
                Chart(parts, id: \.0) { p in
                    SectorMark(angle: .value("GB", p.1), innerRadius: .ratio(0.6), angularInset: 1).foregroundStyle(p.2)
                }
                .frame(width: 150, height: 150)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(parts, id: \.0) { p in
                        HStack { Circle().fill(p.2).frame(width: 9, height: 9); Text(p.0); Spacer(); Text(String(format: "%.0f", p.1)).monospacedDigit() }
                    }
                    HStack { Text("Total"); Spacer(); Text(String(format: "%.0f", m.diskTotalGB)).monospacedDigit() }
                    if m.diskPurgeableGB > 0.5 {
                        Text(String(format: "%.1f GB purgeable", m.diskPurgeableGB)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    func rate(_ b: Double) -> String {
        b > 1_000_000_000 ? String(format: "%.2f GB/s", b / 1e9) : b > 1_000_000 ? String(format: "%.1f MB/s", b / 1e6) : String(format: "%.0f KB/s", b / 1e3)
    }

    var topApps: some View {
        let byMem = Array(m.apps.sorted { $0.memMB > $1.memMB }.prefix(8))
        return Card(title: "Top apps by memory (helpers grouped)") {
            Chart(byMem) { a in
                BarMark(x: .value("MB", a.memMB), y: .value("App", a.name)).foregroundStyle(.indigo)
                    .annotation(position: .trailing) { Text(String(format: "%.1f GB · %.0f%% CPU", a.memMB / 1024, a.cpu)).font(.caption2) }
            }
            .chartXScale(range: .plotDimension(endPadding: 110))
            .frame(height: 220)
        }
    }

    var tipsCard: some View {
        Card(title: "Suggestions to reduce load") {
            ForEach(m.tips, id: \.self) { t in
                Label(t, systemImage: "lightbulb.fill").symbolRenderingMode(.multicolor).font(.callout)
            }
        }
    }
}
