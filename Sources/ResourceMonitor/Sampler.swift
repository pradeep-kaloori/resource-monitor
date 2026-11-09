import Foundation
import Darwin
import IOKit
import AppKit

struct Sample: Identifiable {
    let id = UUID()
    let time: Date
    let cpu: Double          // 0-100
    let memUsed: Double      // 0-100
    let netDown: Double      // bytes/s
    let netUp: Double        // bytes/s
    let diskRead: Double     // bytes/s
    let diskWrite: Double    // bytes/s
}

struct AppUsage: Identifiable {
    var id: String { name }
    let name: String
    var cpu: Double          // % of one core
    var memMB: Double
    var procs: Int
}

struct RunningApp: Identifiable {
    var id: pid_t { app.processIdentifier }
    let app: NSRunningApplication
    let name: String
    let icon: NSImage?
    let cpu: Double
    let memMB: Double
}

struct MemBreakdown {
    var app = 0.0, wired = 0.0, compressed = 0.0, cached = 0.0, free = 0.0   // GB
    var total = 0.0
    var swapUsed = 0.0
    var pressure = 1   // 1 normal, 2 warn, 4 critical
}

@MainActor
final class Monitor: ObservableObject {
    @Published var samples: [Sample] = []
    @Published var perCore: [Double] = []
    @Published var mem = MemBreakdown()
    @Published var diskUsedGB = 0.0
    @Published var diskTotalGB = 0.0
    @Published var diskFreeGB = 0.0
    @Published var diskPurgeableGB = 0.0
    @Published var apps: [AppUsage] = []
    @Published var tips: [String] = []
    @Published var runningApps: [RunningApp] = []
    @Published var cpuHistoryAvg = 0.0

    private var prevTicks: [[UInt32]] = []
    private var prevNet: (UInt64, UInt64, Date)?
    private var prevDisk: (UInt64, UInt64, Date)?
    private var timer: Timer?
    private var tick = 0
    private var started = false
    let maxSamples = 120
    let cores = ProcessInfo.processInfo.processorCount

    func start() {
        guard !started else { return }
        started = true
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    private func sample() {
        tick += 1
        let cpu = readCPU()
        readMemory()
        let net = readNet()
        let dio = readDiskIO()
        if tick % 2 == 1 { readDisk() }
        let s = Sample(time: Date(), cpu: cpu, memUsed: mem.total > 0 ? (mem.app + mem.wired + mem.compressed) / mem.total * 100 : 0,
                       netDown: net.0, netUp: net.1, diskRead: dio.0, diskWrite: dio.1)
        samples.append(s)
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
        cpuHistoryAvg = samples.map(\.cpu).reduce(0, +) / Double(samples.count)
        if tick % 2 == 1 { refreshProcesses() }
    }

    // MARK: CPU
    private func readCPU() -> Double {
        var n: natural_t = 0
        var info: processor_info_array_t?
        var cnt: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &cnt) == KERN_SUCCESS, let info else { return 0 }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(cnt) * vm_size_t(MemoryLayout<integer_t>.size)) }
        var ticks: [[UInt32]] = []
        for i in 0..<Int(n) {
            let b = i * Int(CPU_STATE_MAX)
            ticks.append([UInt32(info[b + Int(CPU_STATE_USER)]), UInt32(info[b + Int(CPU_STATE_SYSTEM)]),
                          UInt32(info[b + Int(CPU_STATE_IDLE)]), UInt32(info[b + Int(CPU_STATE_NICE)])])
        }
        var loads: [Double] = []
        if prevTicks.count == ticks.count {
            for i in 0..<ticks.count {
                let d = zip(ticks[i], prevTicks[i]).map { Double($0 &- $1) }
                let total = d.reduce(0, +)
                loads.append(total > 0 ? (total - d[2]) / total * 100 : 0)
            }
        }
        prevTicks = ticks
        perCore = loads
        return loads.isEmpty ? 0 : loads.reduce(0, +) / Double(loads.count)
    }

    // MARK: Memory
    private func readMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return }
        let page = Double(vm_kernel_page_size)
        let gb = 1024.0 * 1024 * 1024
        var m = MemBreakdown()
        m.total = Double(ProcessInfo.processInfo.physicalMemory) / gb
        m.app = max(0, Double(stats.internal_page_count) - Double(stats.purgeable_count)) * page / gb
        m.wired = Double(stats.wire_count) * page / gb
        m.compressed = Double(stats.compressor_page_count) * page / gb
        m.cached = (Double(stats.external_page_count) + Double(stats.purgeable_count)) * page / gb
        m.free = max(0, m.total - m.app - m.wired - m.compressed - m.cached)
        var sw = xsw_usage()
        var sz = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &sw, &sz, nil, 0) == 0 { m.swapUsed = Double(sw.xsu_used) / gb }
        var lvl: Int32 = 1
        var lsz = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &lvl, &lsz, nil, 0) == 0 { m.pressure = Int(lvl) }
        mem = m
    }

    // MARK: Disk
    private func readDisk() {
        let url = URL(fileURLWithPath: "/")
        if let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]),
           let t = v.volumeTotalCapacity, let a = v.volumeAvailableCapacityForImportantUsage {
            diskTotalGB = Double(t) / 1e9
            diskUsedGB = (Double(t) - Double(a)) / 1e9
            diskFreeGB = Double(a) / 1e9
            // Space macOS can reclaim on demand (caches, local snapshots)
            diskPurgeableGB = max(0, Double(a) - Double(v.volumeAvailableCapacity ?? Int(a))) / 1e9
        }
    }

    private func readDiskIO() -> (Double, Double) {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(it) }
        var r: UInt64 = 0, w: UInt64 = 0
        var e = IOIteratorNext(it)
        while e != 0 {
            if let d = IORegistryEntryCreateCFProperty(e, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                r += (d["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                w += (d["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(e)
            e = IOIteratorNext(it)
        }
        let now = Date()
        defer { prevDisk = (r, w, now) }
        guard let p = prevDisk else { return (0, 0) }
        let dt = now.timeIntervalSince(p.2)
        guard dt > 0 else { return (0, 0) }
        return (Double(r &- p.0) / dt, Double(w &- p.1) / dt)
    }

    // MARK: Network
    private func readNet() -> (Double, Double) {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return (0, 0) }
        defer { freeifaddrs(ifap) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let c = p {
            let name = String(cString: c.pointee.ifa_name)
            if let a = c.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_LINK), name.hasPrefix("en"), let d = c.pointee.ifa_data {
                let data = d.assumingMemoryBound(to: if_data.self).pointee
                rx += UInt64(data.ifi_ibytes); tx += UInt64(data.ifi_obytes)
            }
            p = c.pointee.ifa_next
        }
        let now = Date()
        defer { prevNet = (rx, tx, now) }
        guard let pn = prevNet else { return (0, 0) }
        let dt = now.timeIntervalSince(pn.2)
        guard dt > 0 else { return (0, 0) }
        return (Double(rx &- pn.0) / dt, Double(tx &- pn.1) / dt)
    }

    // MARK: Processes
    private func refreshProcesses() {
        Task.detached(priority: .utility) {
            let out = Monitor.runPS()
            await MainActor.run {
                self.apps = out
                self.runningApps = self.buildRunningApps()
                self.tips = self.buildTips()
            }
        }
    }

    nonisolated static func runPS() -> [AppUsage] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Axo", "pcpu=,rss=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var groups: [String: AppUsage] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let cpu = Double(parts[0]), let rss = Double(parts[1]) else { continue }
            let name = groupName(String(parts[2]))
            var g = groups[name] ?? AppUsage(name: name, cpu: 0, memMB: 0, procs: 0)
            g.cpu += cpu; g.memMB += rss / 1024; g.procs += 1
            groups[name] = g
        }
        return Array(groups.values)
    }

    // Roll helper processes up into their outermost .app
    nonisolated static func groupName(_ path: String) -> String {
        if path.contains("com.apple.Virtualization.VirtualMachine") { return "Virtual Machine (Docker/VM)" }
        if let r = path.range(of: ".app/") {
            return String(path[..<r.lowerBound].split(separator: "/").last ?? "")
        }
        return (path as NSString).lastPathComponent
    }

    // MARK: Actions
    private func buildRunningApps() -> [RunningApp] {
        let byName = Dictionary(uniqueKeysWithValues: apps.map { ($0.name, $0) })
        let vm = byName.first { $0.key.hasPrefix("Virtual Machine") }?.value
        let protected: Set<String> = ["com.apple.finder", Bundle.main.bundleIdentifier ?? ""]
        let list = NSWorkspace.shared.runningApplications.compactMap { a -> RunningApp? in
            guard a.activationPolicy == .regular, let id = a.bundleIdentifier, !protected.contains(id),
                  let file = a.bundleURL?.deletingPathExtension().lastPathComponent else { return nil }
            let u = byName[file]
            var mem = u?.memMB ?? 0, cpu = u?.cpu ?? 0
            // Docker Desktop's VM runs outside the app bundle, so credit it to Docker
            if file.hasPrefix("Docker"), let vm { mem += vm.memMB; cpu += vm.cpu }
            return RunningApp(app: a, name: a.localizedName ?? file, icon: a.icon, cpu: cpu, memMB: mem)
        }
        return Array(list.sorted { $0.memMB > $1.memMB }.prefix(10))
    }

    func quit(_ a: RunningApp) { a.app.terminate() }
    func forceQuit(_ a: RunningApp) { a.app.forceTerminate() }

    // MARK: Advice
    private func buildTips() -> [String] {
        var t: [String] = []
        let topMem = apps.sorted { $0.memMB > $1.memMB }
        let topCPU = apps.sorted { $0.cpu > $1.cpu }
        if mem.pressure >= 2 { t.append("Memory pressure is elevated. Quit apps you aren't using, starting with the top memory users.") }
        if mem.swapUsed > 1 { t.append(String(format: "%.1f GB is swapped to disk. This slows everything down, so close heavy apps or tabs.", mem.swapUsed)) }
        for a in topCPU.prefix(3) where a.cpu > 40 {
            t.append(String(format: "%@ is using %.0f%% of a core right now. Check if it needs to be running.", a.name, a.cpu))
        }
        for a in topMem.prefix(4) where a.memMB > 1500 {
            t.append(String(format: "%@ holds %.1f GB across %d processes.", a.name, a.memMB / 1024, a.procs))
        }
        if let vm = apps.first(where: { $0.name.hasPrefix("Virtual Machine") }), vm.memMB > 500 {
            t.append("A VM (likely Docker Desktop) is running. Quit Docker when you don't need containers, or lower its CPU/memory limits in settings.")
        }
        if let c = apps.first(where: { $0.name == "Google Chrome" }), c.procs > 15 {
            t.append("Chrome has \(c.procs) processes. Close unused tabs or turn on Memory Saver.")
        }
        if let l = samples.last, l.diskWrite > 100e6 { t.append(String(format: "Heavy disk writes (%.0f MB/s). Check for builds, Docker image pulls or backups running.", l.diskWrite / 1e6)) }
        if diskTotalGB > 0, diskUsedGB / diskTotalGB > 0.85 { t.append("Disk is over 85% full. Empty the Trash and clear caches.") }
        if t.isEmpty { t.append("Everything looks healthy.") }
        return t
    }
}
