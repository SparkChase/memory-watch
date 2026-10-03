import Foundation
import Darwin

let gib = 1_073_741_824.0

enum Pressure: Int, Codable {
    case normal = 1, warning = 2, critical = 4, unknown = 0
    var label: String {
        switch self {
        case .normal: return "正常"
        case .warning: return "偏高"
        case .critical: return "严重"
        case .unknown: return "未知"
        }
    }
}

struct Sample: Codable {
    let time: Date
    let pressure: Pressure
    let physical: Double
    let used: Double
    let compressed: Double
    let swapUsed: Double
    let diskFree: Double?
    let diskTotal: Double?
    let swapOutBytes: Double

    var usedFraction: Double { physical > 0 ? min(1, used / physical) : 0 }
}

enum SamplingError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let detail): return "系统采样失败：\(detail)" }
    }
}

enum SystemSampler {
    static func sample() throws -> Sample {
        var raw: Int32 = 0
        var rawSize = MemoryLayout<Int32>.size
        let pressureOK = sysctlbyname("kern.memorystatus_vm_pressure_level", &raw, &rawSize, nil, 0) == 0
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 else {
            throw SamplingError.failed("vm.swapusage")
        }
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &vm) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw SamplingError.failed("host_statistics64") }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else {
            throw SamplingError.failed("host_page_size")
        }
        let physical = Double(ProcessInfo.processInfo.physicalMemory)
        let appPages = max(0, Double(vm.internal_page_count) - Double(vm.purgeable_count))
        let used = min(physical, (appPages + Double(vm.wire_count) + Double(vm.compressor_page_count)) * Double(pageSize))
        // Query the user's data volume, not the read-only system snapshot.
        let disk = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [
            .volumeAvailableCapacityKey, .volumeTotalCapacityKey
        ])
        return Sample(time: Date(), pressure: pressureOK ? (Pressure(rawValue: Int(raw)) ?? .unknown) : .unknown,
                      physical: physical, used: used, compressed: Double(vm.compressor_page_count) * Double(pageSize),
                      swapUsed: Double(swap.xsu_used), diskFree: disk?.volumeAvailableCapacity.map(Double.init),
                      diskTotal: disk?.volumeTotalCapacity.map(Double.init),
                      swapOutBytes: Double(vm.swapouts) * Double(pageSize))
    }
}

struct MemoryProcess: Codable, Identifiable {
    let pid: Int
    let name: String
    let bytes: Double
    var id: Int { pid }
}

enum ProcessSampler {
    static func top() -> [MemoryProcess] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-A", "-o", "pid=,rss=,comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else { return [] }
        return output.split(separator: "\n").compactMap { line -> MemoryProcess? in
            let fields = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard fields.count == 3, let pid = Int(fields[0]), let rss = Double(fields[1]) else { return nil }
            let path = String(fields[2])
            let name = URL(fileURLWithPath: path).lastPathComponent
            return MemoryProcess(pid: pid, name: name, bytes: rss * 1024)
        }.sorted { $0.bytes > $1.bytes }.prefix(5).map { $0 }
    }
}

struct AlertRules {
    var swapGiB: Double = 4
    var diskGiB: Double = 20
    var cooldown: TimeInterval = 900
}

struct AlertSignal: Equatable {
    let kind: String
    let severity: Int
    let title: String
    let body: String
    let dwell: TimeInterval
    var key: String { "\(kind)-\(severity)" }
}

struct AlertEngine {
    private var pending: [String: Date] = [:]
    private var delivered: [String: Date] = [:]
    private var previousSample: Date?

    init(lastDelivered: [String: Date] = [:]) { delivered = lastDelivered }
    var deliveryHistory: [String: Date] { delivered }

    static func signals(_ s: Sample, rules: AlertRules) -> [AlertSignal] {
        var items: [AlertSignal] = []
        if s.pressure == .warning || s.pressure == .critical {
            let critical = s.pressure == .critical
            items.append(AlertSignal(kind: "pressure", severity: critical ? 2 : 1,
                title: critical ? "内存压力已变红" : "内存压力持续偏高",
                body: "swap \(formatGiB(s.swapUsed))。建议保存工作，并检查占用较大的应用。",
                dwell: critical ? 0 : 30))
        }
        if s.swapUsed >= rules.swapGiB * gib {
            let critical = s.swapUsed >= max(8, rules.swapGiB * 2) * gib
            items.append(AlertSignal(kind: "swap", severity: critical ? 2 : 1,
                title: "swap 已达 \(formatGiB(s.swapUsed))",
                body: s.pressure == .normal ? "当前内存压力正常；swap 较高不一定表示正在卡顿，可留意后续变化。" : "内存压力\(s.pressure.label)，建议检查占用较大的应用。",
                dwell: critical ? 30 : 60))
        }
        if let free = s.diskFree, free < rules.diskGiB * gib {
            let critical = free < min(10, rules.diskGiB / 2) * gib
            items.append(AlertSignal(kind: "disk", severity: critical ? 2 : 1,
                title: "磁盘仅剩 \(formatGiB(free))",
                body: "启动盘空间偏少，可能影响 swap 和应用运行。请检查不再需要的大文件。",
                dwell: critical ? 30 : 60))
        }
        return items
    }

    mutating func evaluate(_ s: Sample, rules: AlertRules) -> [AlertSignal] {
        // Sleep, clock changes and sampling gaps must not count toward a sustained condition.
        if let prior = previousSample, s.time.timeIntervalSince(prior) > 15 || s.time < prior {
            pending.removeAll()
            if s.time < prior { delivered.removeAll() }
        }
        previousSample = s.time
        let active = Self.signals(s, rules: rules)
        let keys = Set(active.map(\.key))
        pending = pending.filter { keys.contains($0.key) }
        var ready: [AlertSignal] = []
        for alert in active {
            if pending[alert.key] == nil { pending[alert.key] = s.time }
            let sustained = s.time.timeIntervalSince(pending[alert.key]!) >= alert.dwell
            let cooled = delivered[alert.key].map { s.time.timeIntervalSince($0) >= rules.cooldown } ?? true
            if sustained && cooled {
                ready.append(alert)
                delivered[alert.key] = s.time
                // A severe incident also suppresses a lower-level follow-up in the cooldown window.
                if alert.severity == 2 { delivered["\(alert.kind)-1"] = s.time }
            }
        }
        return ready
    }

    mutating func resetPending() { pending.removeAll(); previousSample = nil }
}

struct Incident: Codable, Identifiable {
    let id: UUID
    let time: Date
    let title: String
    let body: String
    let sample: Sample
    let processes: [MemoryProcess]
}

// All mutable state, including the JSON coders, is protected by lock.
final class HistoryStore: @unchecked Sendable {
    let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var lineCount = 0
    private let lock = NSLock()

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func loadSamples() -> [Sample] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("samples.jsonl")) else { return [] }
        let lines = data.split(separator: 10)
        lineCount = lines.count
        let cutoff = Date().addingTimeInterval(-86400)
        return lines.suffix(1440).compactMap { try? decoder.decode(Sample.self, from: Data($0)) }
            .filter { $0.time > cutoff && $0.time <= Date() }
    }

    func append(_ sample: Sample, retained: [Sample]) throws {
        lock.lock(); defer { lock.unlock() }
        let url = directory.appendingPathComponent("samples.jsonl")
        if lineCount >= 2048 {
            var data = Data()
            for item in retained.suffix(1439) { data.append(try encoder.encode(item)); data.append(10) }
            try data.write(to: url, options: .atomic)
            lineCount = min(1439, retained.count)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url, options: .atomic)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var data = try encoder.encode(sample)
        data.append(10)
        try handle.write(contentsOf: data)
        lineCount += 1
    }

    func loadIncidents() -> [Incident] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("incidents.json")) else { return [] }
        return (try? decoder.decode([Incident].self, from: data)) ?? []
    }

    func saveIncidents(_ incidents: [Incident]) throws {
        lock.lock(); defer { lock.unlock() }
        try encoder.encode(Array(incidents.suffix(200))).write(to: directory.appendingPathComponent("incidents.json"), options: .atomic)
    }
}

func formatGiB(_ bytes: Double) -> String { String(format: "%.1f GiB", bytes / gib) }

func formatMemory(_ bytes: Double) -> String {
    bytes >= gib ? formatGiB(bytes) : String(format: "%.0f MiB", bytes / 1_048_576)
}
