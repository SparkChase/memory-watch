import Foundation

@main
struct CoreTests {
    static var checks = 0
    static let base = Date()
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError("FAIL: \(message)") }
    }
    static func sample(_ t: Double, _ pressure: Pressure = .normal, swap: Double = 0, disk: Double? = 100) -> Sample {
        Sample(time: base.addingTimeInterval(t), pressure: pressure, physical: 24 * gib, used: 18 * gib,
               compressed: 4 * gib, swapUsed: swap * gib, diskFree: disk.map { $0 * gib }, diskTotal: 1000 * gib, swapOutBytes: 0)
    }
    static func feed(_ engine: inout AlertEngine, from: Int, through: Int, pressure: Pressure = .normal,
                     swap: Double = 0, disk: Double? = 100, rules: AlertRules = AlertRules()) -> [AlertSignal] {
        stride(from: from, through: through, by: 5).flatMap {
            engine.evaluate(sample(Double($0), pressure, swap: swap, disk: disk), rules: rules)
        }
    }
    static func main() throws {
        var engine = AlertEngine()
        expect(feed(&engine, from: 0, through: 100).isEmpty, "healthy samples remain quiet")
        engine = AlertEngine()
        expect(feed(&engine, from: 0, through: 25, pressure: .warning).isEmpty, "yellow waits 30 seconds")
        expect(engine.evaluate(sample(30, .warning), rules: AlertRules()).map(\.kind) == ["pressure"], "yellow alerts at 30 seconds")
        expect(feed(&engine, from: 35, through: 925, pressure: .warning).isEmpty, "yellow cooldown")
        expect(engine.evaluate(sample(930, .warning), rules: AlertRules()).count == 1, "persistent condition repeats after cooldown")
        expect(engine.evaluate(sample(935, .critical), rules: AlertRules()).first?.severity == 2, "red bypasses yellow cooldown")
        expect(feed(&engine, from: 940, through: 1000, pressure: .warning).isEmpty, "red suppresses downgrade notification")

        engine = AlertEngine()
        expect(engine.evaluate(sample(0, .critical), rules: AlertRules()).count == 1, "red immediate at launch")
        expect(feed(&engine, from: 5, through: 60, pressure: .critical).isEmpty, "red does not spam")
        var restored = AlertEngine(lastDelivered: engine.deliveryHistory)
        expect(restored.evaluate(sample(65, .critical), rules: AlertRules()).isEmpty, "restart preserves cooldown")
        expect(engine.evaluate(sample(-100, .critical), rules: AlertRules()).count == 1, "backward clock does not suppress alerts indefinitely")

        engine = AlertEngine()
        _ = feed(&engine, from: 0, through: 25, pressure: .warning)
        _ = engine.evaluate(sample(30), rules: AlertRules())
        expect(feed(&engine, from: 35, through: 60, pressure: .warning).isEmpty, "brief recovery resets dwell")
        expect(engine.evaluate(sample(65, .warning), rules: AlertRules()).count == 1, "new continuous warning eventually alerts")

        engine = AlertEngine()
        _ = feed(&engine, from: 0, through: 25, pressure: .warning)
        expect(engine.evaluate(sample(3600, .warning), rules: AlertRules()).isEmpty, "sleep does not count as sustained pressure")
        expect(feed(&engine, from: 3605, through: 3625, pressure: .warning).isEmpty, "wake gets fresh dwell")
        expect(engine.evaluate(sample(3630, .warning), rules: AlertRules()).count == 1, "sustained after wake alerts")

        engine = AlertEngine()
        expect(feed(&engine, from: 0, through: 55, swap: 4).isEmpty, "swap warning waits 60 seconds")
        expect(engine.evaluate(sample(60, swap: 4), rules: AlertRules()).first?.kind == "swap", "swap alerts while pressure is green")
        expect(feed(&engine, from: 65, through: 90, swap: 11).isEmpty, "severe swap waits 30 seconds")
        expect(engine.evaluate(sample(95, swap: 11), rules: AlertRules()).first?.severity == 2, "11 GiB swap upgrades warning")

        engine = AlertEngine()
        expect(feed(&engine, from: 0, through: 60, swap: 3.9).isEmpty, "below swap threshold is quiet")
        engine = AlertEngine()
        expect(feed(&engine, from: 0, through: 55, disk: 19).isEmpty, "low disk sustained 60 seconds")
        expect(engine.evaluate(sample(60, disk: 19), rules: AlertRules()).first?.kind == "disk", "disk warning works independently")
        engine = AlertEngine()
        expect(feed(&engine, from: 0, through: 30, disk: 9).first?.severity == 2, "very low disk uses faster severe rule")
        engine = AlertEngine()
        expect(feed(&engine, from: 0, through: 100, disk: nil).isEmpty, "missing disk data is not a false zero")
        engine = AlertEngine()
        expect(feed(&engine, from: 0, through: 30, pressure: .critical, swap: 11, disk: 9).map(\.kind).sorted() == ["disk", "pressure", "swap"], "multiple independent signals preserved")
        engine = AlertEngine()
        expect(feed(&engine, from: 0, through: 60, pressure: .unknown, swap: 5).first?.kind == "swap", "unknown pressure does not mask swap alerts")
        engine = AlertEngine()
        expect(feed(&engine, from: 0, through: 90, swap: 6, rules: AlertRules(swapGiB: 8)).isEmpty, "custom swap threshold is respected")
        _ = feed(&engine, from: 95, through: 120, pressure: .warning)
        engine.resetPending()
        expect(engine.evaluate(sample(125, .warning), rules: AlertRules()).isEmpty, "resuming alerts starts new dwell")

        let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("test-\(UUID().uuidString)")
        let store = try HistoryStore(directory: directory)
        let s = sample(-60, .warning, swap: 11)
        try store.append(s, retained: [])
        expect(store.loadSamples().count == 1, "history round trip")
        let event = Incident(id: UUID(), time: s.time, title: "测试", body: "测试", sample: s,
                             processes: [MemoryProcess(pid: 123, name: "App Name", bytes: gib)])
        try store.saveIncidents([event])
        expect(store.loadIncidents().first?.processes.first?.name == "App Name", "incident preserves process context")
        try store.saveIncidents(Array(repeating: event, count: 250))
        expect(store.loadIncidents().count == 200, "incident log stays bounded")
        let handle = try FileHandle(forWritingTo: directory.appendingPathComponent("samples.jsonl"))
        try handle.seekToEnd(); try handle.write(contentsOf: Data("bad partial record\n".utf8)); try handle.close()
        expect(store.loadSamples().count == 1, "damaged line does not discard valid history")
        var bulk = Data()
        let encoder = JSONEncoder()
        for _ in 0..<2050 { bulk.append(try encoder.encode(s)); bulk.append(10) }
        try bulk.write(to: directory.appendingPathComponent("samples.jsonl"))
        let retained = store.loadSamples()
        expect(retained.count == 1440, "large log loads bounded history")
        try store.append(sample(-30), retained: retained)
        let boundedData = try Data(contentsOf: directory.appendingPathComponent("samples.jsonl"))
        expect(boundedData.split(separator: 10).count == 1440, "log compacts without deleting files")
        let live = try SystemSampler.sample()
        expect(live.physical > 0 && live.used >= 0 && live.used <= live.physical, "live memory readings valid")
        expect(live.swapUsed >= 0 && live.diskFree != nil, "live swap and disk available")
        let processes = ProcessSampler.top()
        expect(!processes.isEmpty && processes.count <= 5, "live processes available")
        expect(zip(processes, processes.dropFirst()).allSatisfy { $0.bytes >= $1.bytes }, "processes sorted by RSS")
        print("PASS: \(checks) checks (alert timing, escalation, cooldown, sleep, thresholds, persistence, live sampling)")
    }
}
