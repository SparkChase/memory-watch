import AppKit
import SwiftUI
import UserNotifications
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var model: Monitor!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Opening a second installed copy should bring the first one forward.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "local.trace.MemoryWatch")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let existing = others.first {
            existing.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        model = Monitor()
        UNUserNotificationCenter.current().delegate = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "内存 · 采样中"
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        }
        popover.contentSize = NSSize(width: 400, height: 680)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MonitorPanel(model: model))
        model.onChange = { [weak self] in self?.updateStatus() }
        model.onOpen = { [weak self] in self?.showPopover() }
        model.start()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        let firstLaunch = !UserDefaults.standard.bool(forKey: "hasLaunched")
        if firstLaunch {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.model.tab = 2
                self?.showPopover()
                self?.model.requestNotifications()
            }
        }
    }

    @objc func woke() { model.sampleNow(); model.refreshAuthorization() }

    func updateStatus() {
        guard let button = statusItem.button else { return }
        if model.samplingError != nil {
            button.title = "内存 · 读取失败"
            button.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "读取失败")
            button.toolTip = model.samplingError
            return
        }
        guard let s = model.sample else { return }
        let diskLow = (s.diskFree ?? .infinity) < model.diskGiB * gib
        let swapHigh = s.swapUsed >= model.swapGiB * gib
        let abnormal = s.pressure == .warning || s.pressure == .critical || diskLow || swapHigh
        let label = s.pressure == .normal && diskLow ? "磁盘偏少" : (s.pressure == .normal && swapHigh ? "swap偏高" : s.pressure.label)
        button.title = " \(label) · S \(String(format: "%.1f", s.swapUsed / gib))G"
        button.image = NSImage(systemSymbolName: abnormal ? "exclamationmark.triangle.fill" : "memorychip", accessibilityDescription: "内存压力\(s.pressure.label)")
        button.image?.isTemplate = true
        button.contentTintColor = s.pressure == .critical ? .systemRed : (abnormal ? .systemOrange : nil)
        button.imagePosition = .imageLeading
        button.toolTip = "内存压力\(s.pressure.label)\n内存 \(formatGiB(s.used)) / \(formatGiB(s.physical))\nswap \(formatGiB(s.swapUsed))\n磁盘可用 \(s.diskFree.map(formatGiB) ?? "未知")\n点击查看；S 表示 swap，G 表示 GiB"
        button.setAccessibilityLabel(button.toolTip)
    }

    @objc func togglePopover() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "打开内存哨兵", action: #selector(openPanel), keyEquivalent: "").target = self
            menu.addItem(withTitle: "打开活动监视器", action: #selector(activityMonitor), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出内存哨兵", action: #selector(quit), keyEquivalent: "q").target = self
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else if popover.isShown { popover.performClose(nil) }
        else { showPopover() }
    }

    @objc func openPanel() { showPopover() }
    @objc func activityMonitor() { model.openActivityMonitor() }
    @objc func quit() { NSApp.terminate(nil) }

    func showPopover() {
        guard let button = statusItem.button else { return }
        model.refreshAuthorization()
        model.refreshLogin()
        model.refreshProcesses()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            self?.model.tab = 1
            self?.showPopover()
            completionHandler()
        }
    }
}

try MainActor.assumeIsolated {
if CommandLine.arguments.contains("--diagnostics") {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    print("loginStatus=\(SMAppService.mainApp.status.rawValue)")
    if let url = Bundle.main.url(forResource: "MemoryAlert", withExtension: "aiff"),
       let voice = NSSound(contentsOf: url, byReference: true) {
        print("voiceFile=\(url.lastPathComponent) duration=\(voice.duration)")
    } else { print("voiceFile=missing-or-unreadable") }
    UNUserNotificationCenter.current().getNotificationSettings { settings in
        print("notificationAuthorization=\(settings.authorizationStatus.rawValue) alertSetting=\(settings.alertSetting.rawValue) soundSetting=\(settings.soundSetting.rawValue)")
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            print("deliveredNotifications=\(delivered.count)")
            exit(0)
        }
    }
    RunLoop.main.run(until: Date().addingTimeInterval(10))
    exit(1)
} else if CommandLine.arguments.contains("--test-notification") {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let model = Monitor()
    let started = Date()
    let expectsVoice = model.sound && model.voiceAlert && model.voiceURL != nil
    var observedVoiceTime: TimeInterval = 0
    model.testNotification()
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        observedVoiceTime = model.voiceTime
        print("voiceStarted=\(model.voiceStarted) voiceTime=\(observedVoiceTime)")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let found = delivered.contains { $0.request.identifier.hasPrefix("test-") && $0.date >= started }
            DispatchQueue.main.async {
                print("testNotificationAccepted=\(String(describing: model.lastNotificationAccepted)) stillInNotificationCenter=\(found) voiceFinished=\(String(describing: model.voiceFinished))")
                exit(model.lastNotificationAccepted == true && (!expectsVoice || model.voiceStarted && observedVoiceTime > 0 && model.voiceFinished == true) ? 0 : 2)
            }
        }
    }
    RunLoop.main.run(until: Date().addingTimeInterval(15))
    exit(1)
} else if CommandLine.arguments.contains("--sample") {
    do {
        let s = try SystemSampler.sample()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        print(String(data: try encoder.encode(s), encoding: .utf8)!)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if let flag = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > flag + 1 {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let model = Monitor(preview: true)
    model.sample = try? SystemSampler.sample()
    model.processes = ProcessSampler.top()
    if CommandLine.arguments.contains("--settings") { model.tab = 2 }
    if CommandLine.arguments.contains("--events") { model.tab = 1 }
    if CommandLine.arguments.contains("--warning"), let s = model.sample {
        model.sample = Sample(time: s.time, pressure: .warning, physical: s.physical, used: 22 * gib, compressed: 6 * gib,
            swapUsed: 11 * gib, diskFree: 15 * gib, diskTotal: s.diskTotal, swapOutBytes: s.swapOutBytes)
        model.history = (0..<60).map { i in
            Sample(time: s.time.addingTimeInterval(Double(i - 60) * 60), pressure: i > 40 ? .warning : .normal,
                   physical: s.physical, used: s.used, compressed: s.compressed, swapUsed: Double(i) / 59 * 11 * gib,
                   diskFree: s.diskFree, diskTotal: s.diskTotal, swapOutBytes: 0)
        }
    }
    let view = NSHostingView(rootView: MonitorPanel(model: model))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 680), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
    window.contentView = view
    window.display()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    view.layoutSubtreeIfNeeded()
    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
        }
    }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
}
