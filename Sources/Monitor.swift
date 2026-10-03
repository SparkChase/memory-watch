import AppKit
import SwiftUI
import UserNotifications
import ServiceManagement

@MainActor
final class Monitor: NSObject, ObservableObject, NSSoundDelegate {
    @Published var sample: Sample?
    @Published var history: [Sample] = []
    @Published var incidents: [Incident] = []
    @Published var processes: [MemoryProcess] = []
    @Published var samplingError: String?
    @Published var storageError: String?
    @Published var actionMessage: String?
    @Published var notificationStatus = "正在检查…"
    @Published var notificationAllowed = false
    @Published var notificationSoundAllowed = false
    @Published var loginEnabled = false
    @Published var loginNeedsApproval = false
    @Published var processLoading = false
    @Published var processTime: Date?
    @Published var swapWriteRate: Double = 0
    @Published var tab = 0
    @Published var sound: Bool { didSet { defaults.set(sound, forKey: "sound"); if !sound { stopVoice() } } }
    @Published var voiceAlert: Bool { didSet { defaults.set(voiceAlert, forKey: "voiceAlert"); stopVoice() } }
    @Published var voicePlaying = false
    @Published var alertsEnabled: Bool { didSet { defaults.set(alertsEnabled, forKey: "alertsEnabled"); engine.resetPending() } }
    @Published var swapGiB: Double { didSet { defaults.set(swapGiB, forKey: "swapGiB"); engine.resetPending() } }
    @Published var diskGiB: Double { didSet { defaults.set(diskGiB, forKey: "diskGiB"); engine.resetPending() } }
    @Published var cooldownMinutes: Double { didSet { defaults.set(cooldownMinutes, forKey: "cooldownMinutes") } }

    var onChange: (() -> Void)?
    var onOpen: (() -> Void)?
    private let defaults: UserDefaults
    private var engine = AlertEngine()
    private var timer: Timer?
    private let queue = DispatchQueue(label: "local.memorywatch.sampling", qos: .utility)
    private var sampling = false
    private var lastHistoryDate: Date?
    private var store: HistoryStore?
    private var voicePlayer: NSSound?
    private(set) var voiceStarted = false
    private(set) var voiceFinished: Bool?
    private(set) var lastNotificationAccepted: Bool?
    var voiceTime: TimeInterval { voicePlayer?.currentTime ?? 0 }
    static let voiceFilename = "MemoryAlert.aiff"
    var voiceURL: URL? { Bundle.main.url(forResource: "MemoryAlert", withExtension: "aiff") }
    var rules: AlertRules { AlertRules(swapGiB: swapGiB, diskGiB: diskGiB, cooldown: cooldownMinutes * 60) }
    var signals: [AlertSignal] { sample.map { AlertEngine.signals($0, rules: rules) } ?? [] }
    var storageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MemoryWatch")
    }

    init(preview: Bool = false) {
        defaults = preview ? UserDefaults(suiteName: "local.memorywatch.preview")! : .standard
        defaults.register(defaults: ["sound": true, "voiceAlert": true, "alertsEnabled": true, "swapGiB": 4.0, "diskGiB": 20.0, "cooldownMinutes": 15.0])
        sound = defaults.bool(forKey: "sound")
        voiceAlert = defaults.bool(forKey: "voiceAlert")
        alertsEnabled = defaults.bool(forKey: "alertsEnabled")
        swapGiB = max(1, defaults.double(forKey: "swapGiB"))
        diskGiB = max(5, defaults.double(forKey: "diskGiB"))
        cooldownMinutes = max(1, defaults.double(forKey: "cooldownMinutes"))
        super.init()
        if preview { return }
        let lastDelivered = (defaults.dictionary(forKey: "lastDelivered") as? [String: Date] ?? [:])
            .filter { $0.value <= Date() && Date().timeIntervalSince($0.value) < 86400 }
        engine = AlertEngine(lastDelivered: lastDelivered)
        do {
            store = try HistoryStore(directory: storageURL)
            history = store!.loadSamples()
            incidents = store!.loadIncidents()
            lastHistoryDate = history.last?.time
        } catch { storageError = "无法保存记录：\(error.localizedDescription)" }
    }

    func start() {
        sampleNow()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleNow() }
        }
        timer?.tolerance = 0.5
        RunLoop.main.add(timer!, forMode: .common)
        refreshAuthorization()
        refreshLogin()
    }

    func sampleNow() {
        guard !sampling else { return }
        sampling = true
        queue.async { [weak self] in
            let result = Result { try SystemSampler.sample() }
            DispatchQueue.main.async { self?.accept(result) }
        }
    }

    private func accept(_ result: Result<Sample, Error>) {
        sampling = false
        switch result {
        case .failure(let error):
            samplingError = error.localizedDescription
            engine.resetPending()
            onChange?()
        case .success(let next):
            samplingError = nil
            if let previous = sample {
                let elapsed = next.time.timeIntervalSince(previous.time)
                swapWriteRate = elapsed > 0 && elapsed < 15 ? max(0, next.swapOutBytes - previous.swapOutBytes) / elapsed : 0
            }
            sample = next
            let cutoff = next.time.addingTimeInterval(-86400)
            history.removeAll { $0.time < cutoff }
            if lastHistoryDate == nil || next.time.timeIntervalSince(lastHistoryDate!) >= 60 || next.time < lastHistoryDate! {
                let retained = history
                history.append(next)
                history = Array(history.suffix(1440))
                lastHistoryDate = next.time
                if let store {
                    queue.async { [weak self] in
                        do { try store.append(next, retained: retained) }
                        catch { DispatchQueue.main.async { self?.storageError = "趋势记录保存失败：\(error.localizedDescription)" } }
                    }
                }
            }
            if alertsEnabled {
                let alerts = engine.evaluate(next, rules: rules)
                if !alerts.isEmpty {
                    defaults.set(engine.deliveryHistory, forKey: "lastDelivered")
                    recordAndNotify(alerts, sample: next)
                }
            }
            onChange?()
        }
    }

    private func recordAndNotify(_ alerts: [AlertSignal], sample: Sample) {
        queue.async { [weak self] in
            let top = ProcessSampler.top()
            DispatchQueue.main.async {
                guard let self else { return }
                let title = alerts.map(\.title).joined(separator: " · ")
                let body = alerts.map(\.body).joined(separator: "\n")
                let incident = Incident(id: UUID(), time: sample.time, title: title, body: body, sample: sample, processes: top)
                self.incidents.append(incident)
                self.incidents = Array(self.incidents.suffix(200))
                let retained = self.incidents
                if let store = self.store {
                    self.queue.async { [weak self] in
                        do { try store.saveIncidents(retained) }
                        catch { DispatchQueue.main.async { self?.storageError = "告警记录保存失败：\(error.localizedDescription)" } }
                    }
                }
                let processHint = top.first.map { "\n当前较大进程：\($0.name)（RSS \(formatMemory($0.bytes))）。" } ?? ""
                self.sendNotification(title: title, body: body + processHint, identifier: "incident-\(incident.id)")
            }
        }
    }

    func refreshProcesses(force: Bool = false) {
        guard !processLoading else { return }
        if !force, let processTime, Date().timeIntervalSince(processTime) < 30 { return }
        processLoading = true
        queue.async { [weak self] in
            let top = ProcessSampler.top()
            DispatchQueue.main.async {
                self?.processes = top
                self?.processTime = Date()
                self?.processLoading = false
            }
        }
    }

    func refreshAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.notificationAllowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                self?.notificationSoundAllowed = settings.soundSetting == .enabled
                switch settings.authorizationStatus {
                case .authorized: self?.notificationStatus = settings.alertSetting == .enabled ? "系统通知已允许" : "已授权，横幅未开启"
                case .provisional: self?.notificationStatus = "已允许静默通知"
                case .denied: self?.notificationStatus = "通知未允许，异常仍会记录"
                case .notDetermined: self?.notificationStatus = "尚未开启通知"
                @unknown default: self?.notificationStatus = "请检查系统通知设置"
                }
            }
        }
    }

    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error { self?.actionMessage = error.localizedDescription }
                self?.refreshAuthorization()
            }
        }
    }

    func testNotification() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                if settings.authorizationStatus == .notDetermined {
                    self.requestNotifications()
                    self.actionMessage = "请先允许通知，再点一次测试。"
                } else if settings.authorizationStatus == .denied {
                    self.actionMessage = "请在系统设置 → 通知 → 内存哨兵中允许通知。"
                    self.openNotificationSettings()
                } else {
                    self.sendNotification(title: "内存哨兵正在守候", body: "这是测试通知。内存压力、swap 或磁盘空间持续异常时，会在这里提醒你。", identifier: "test-\(UUID())")
                }
            }
        }
    }

    private func sendNotification(title: String, body: String, identifier: String) {
        lastNotificationAccepted = nil
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = selectedNotificationSound
        let speak = sound && voiceAlert && voiceURL != nil
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastNotificationAccepted = error == nil
                if let error {
                    self.actionMessage = "通知发送失败：\(error.localizedDescription)"
                } else if speak && self.sound && self.voiceAlert {
                    // The macOS notification service may silently fail to play a named sound.
                    // Use the same in-process audio path as the explicit preview instead.
                    self.playVoice()
                }
            }
        }
    }

    var selectedNotificationSound: UNNotificationSound? {
        guard sound else { return nil }
        guard voiceAlert, voiceURL != nil else { return .default }
        // Speech is played by the app. Keep the banner silent to prevent double audio.
        return nil
    }

    func previewVoice() {
        if voicePlaying { stopVoice() } else { playVoice() }
    }

    private func playVoice() {
        guard !voicePlaying else { return }
        voiceStarted = false
        voiceFinished = nil
        guard let url = voiceURL, let audio = NSSound(contentsOf: url, byReference: true) else {
            actionMessage = "无法读取语音文件，请重新打开应用后重试。"
            return
        }
        audio.delegate = self
        voicePlayer = audio
        voiceStarted = audio.play()
        voicePlaying = voiceStarted
        if !voiceStarted { actionMessage = "语音播放失败，请检查声音输出设备。" }
    }

    private func stopVoice() {
        voicePlayer?.delegate = nil
        voicePlayer?.stop()
        voicePlayer = nil
        voicePlaying = false
        voiceFinished = nil
    }

    nonisolated func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.voicePlayer === sound else { return }
            self.voicePlaying = false
            self.voiceFinished = flag
            if !flag { self.actionMessage = "语音播放未完成，请检查声音输出设备。" }
        }
    }

    func refreshLogin() {
        loginEnabled = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            actionMessage = nil
        } catch { actionMessage = "登录启动设置失败：\(error.localizedDescription)" }
        refreshLogin()
        if loginNeedsApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func openNotificationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }

    func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }

    func exportHistory() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "内存哨兵-记录.json"
        panel.title = "导出最近 24 小时趋势和告警记录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        struct Export: Codable { let samples: [Sample]; let incidents: [Incident] }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(Export(samples: history, incidents: incidents)).write(to: url, options: .atomic)
            actionMessage = "已导出到 \(url.lastPathComponent)"
        } catch { actionMessage = "导出失败：\(error.localizedDescription)" }
    }
}
