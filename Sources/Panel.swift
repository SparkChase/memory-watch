import AppKit
import SwiftUI

enum Palette {
    static let secondary = Color.primary.opacity(0.68)
    static let healthy = adaptive(light: (0.45, 0.12, 140), dark: (0.80, 0.14, 140))
    static let warning = adaptive(light: (0.47, 0.10, 70), dark: (0.82, 0.14, 80))
    static let critical = adaptive(light: (0.49, 0.18, 25), dark: (0.76, 0.14, 25))
    // Native colors composed in OKLCH, converted to sRGB at the AppKit boundary.
    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let (l, c, h) = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            let a = c * cos(h * .pi / 180), b = c * sin(h * .pi / 180)
            let ll = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
            let mm = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
            let ss = pow(l - 0.0894841775 * a - 1.291485548 * b, 3)
            func gamma(_ v: Double) -> Double { max(0, min(1, v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055)) }
            return NSColor(srgbRed: gamma(4.0767416621 * ll - 3.3077115913 * mm + 0.2309699292 * ss),
                           green: gamma(-1.2684380046 * ll + 2.6097574011 * mm - 0.3413193965 * ss),
                           blue: gamma(-0.0041960863 * ll - 0.7034186147 * mm + 1.707614701 * ss), alpha: 1)
        })
    }
}

extension Pressure {
    var color: Color {
        switch self {
        case .normal: return Palette.healthy
        case .warning: return Palette.warning
        case .critical: return Palette.critical
        case .unknown: return .secondary
        }
    }
    var symbol: String {
        switch self {
        case .normal: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}

struct MonitorPanel: View {
    @ObservedObject var model: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Image(systemName: "memorychip").font(.system(size: 23)).foregroundStyle(Palette.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("内存哨兵").font(.system(size: 16, weight: .semibold))
                    if model.notificationAllowed {
                        Text("每 5 秒检查 · 本地记录").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    } else {
                        Button("通知未开启 · 点此设置") { model.tab = 2; model.requestNotifications() }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.warning)
                    }
                }
                Spacer()
                if let sample = model.sample {
                    Label(sample.pressure.label, systemImage: sample.pressure.symbol)
                        .foregroundStyle(sample.pressure.color).font(.system(size: 13, weight: .medium))
                        .accessibilityLabel("内存压力\(sample.pressure.label)")
                }
            }
            Picker("页面", selection: $model.tab) {
                Text("概览").tag(0)
                Text("告警记录").tag(1)
                Text("设置").tag(2)
            }.pickerStyle(.segmented).labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = model.samplingError { message(error + "，正在重试。显示的是上次数据。", symbol: "exclamationmark.triangle") }
                    if let error = model.storageError { message(error, symbol: "externaldrive.badge.exclamationmark") }
                    if model.tab == 0 { overview }
                    else if model.tab == 1 { incidentList }
                    else { settings }
                    if let message = model.actionMessage {
                        Text(message).font(.system(size: 11)).foregroundStyle(Palette.secondary).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 4)
            }
            Divider()
            HStack {
                Button("活动监视器", systemImage: "waveform.path.ecg") { model.openActivityMonitor() }
                    .help("在活动监视器的“内存”页查看应用占用")
                Spacer()
                Menu {
                    Button("导出记录…") { model.exportHistory() }
                    Button("打开记录文件夹") { NSWorkspace.shared.open(model.storageURL) }
                    Divider()
                    Button("退出内存哨兵") { NSApp.terminate(nil) }.keyboardShortcut("q")
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("更多操作")
            }.controlSize(.small)
        }
        .padding(20)
        .frame(width: 400, height: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.refreshProcesses(); model.refreshAuthorization(); model.refreshLogin() }
    }

    @ViewBuilder private var overview: some View {
        if let s = model.sample {
            VStack(alignment: .leading, spacing: 6) {
                Text(headline(s)).font(.system(size: 15, weight: .semibold))
                Text(explanation(s)).font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 10) {
                metric("内存已用", value: "\(formatGiB(s.used)) / \(String(format: "%.0f", s.physical / gib)) GiB", fraction: s.usedFraction, color: s.pressure.color)
                HStack {
                    Text("其中压缩内存").foregroundStyle(Palette.secondary)
                    Spacer()
                    Text(formatGiB(s.compressed)).monospacedDigit()
                }.font(.system(size: 11))
                metric("swap", value: formatGiB(s.swapUsed), fraction: min(1, s.swapUsed / (max(8, model.swapGiB * 2) * gib)), color: s.swapUsed >= model.swapGiB * gib ? Palette.warning : Palette.secondary)
                HStack {
                    Text("当前换出速率").foregroundStyle(Palette.secondary)
                    Spacer()
                    Text(String(format: "%.1f MiB/s", model.swapWriteRate / 1_048_576)).monospacedDigit()
                }.font(.system(size: 11))
                HStack {
                    Label("磁盘可用", systemImage: "internaldrive")
                    Spacer()
                    Text(s.diskFree.map(formatGiB) ?? "暂不可读").monospacedDigit()
                        .foregroundStyle((s.diskFree ?? .infinity) < model.diskGiB * gib ? Palette.warning : Color.primary)
                }.font(.system(size: 12))
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("最近 1 小时 · swap").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("24h 峰值 \(formatGiB(model.history.map(\.swapUsed).max() ?? s.swapUsed))")
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                }
                SwapChart(history: model.history, current: s)
                    .frame(height: 54)
                Text("下方色点表示当时内存压力；休眠期间不采样。")
                    .font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("占用较大的进程").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button { model.refreshProcesses(force: true) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).disabled(model.processLoading).help("刷新进程占用")
                        .accessibilityLabel("刷新进程占用")
                }
                if model.processes.isEmpty {
                    Text(model.processLoading ? "正在读取进程…" : "暂时无法读取，点刷新重试。")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
                ForEach(model.processes) { process in
                    HStack(spacing: 8) {
                        Text(process.name).lineLimit(1).truncationMode(.middle).help("\(process.name) · PID \(process.pid)")
                        Spacer(minLength: 4)
                        Text(formatMemory(process.bytes)).monospacedDigit().foregroundStyle(Palette.secondary)
                    }.font(.system(size: 11))
                }
                Text("RSS 近似值，子进程分别列出；口径与活动监视器不同。")
                    .font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } else if model.samplingError == nil {
            Text("正在读取内存、swap 和磁盘状态…").font(.system(size: 13)).foregroundStyle(Palette.secondary)
        }
    }

    private func headline(_ s: Sample) -> String {
        if s.pressure == .critical { return "内存压力严重，建议尽快检查" }
        if s.pressure == .warning { return "内存正在吃紧" }
        if s.pressure == .unknown { return "暂时无法确定内存压力" }
        if (s.diskFree ?? .infinity) < model.diskGiB * gib { return "内存压力正常，磁盘空间偏少" }
        if s.swapUsed >= model.swapGiB * gib { return "内存压力正常，swap 较高" }
        return "当前内存压力正常"
    }

    private func explanation(_ s: Sample) -> String {
        if s.pressure == .warning || s.pressure == .critical { return "先保存工作，再查看占用较大的应用。" }
        if s.pressure == .unknown { return "swap 和容量仍在监控，系统压力状态暂不可读。" }
        return "持续异常时会提醒你；swap 数值高不一定代表正在卡顿。"
    }

    private func metric(_ label: String, value: String, fraction: Double, color: Color) -> some View {
        VStack(spacing: 6) {
            HStack { Text(label); Spacer(); Text(value).monospacedDigit() }.font(.system(size: 12))
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(color).frame(width: max(0, g.size.width * fraction))
                }
            }.frame(height: 4).accessibilityHidden(true)
        }.accessibilityElement(children: .combine)
    }

    private func message(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
    }

    private var incidentList: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("最近 \(model.incidents.count) 次告警").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("导出…") { model.exportHistory() }.controlSize(.small)
            }
            if model.incidents.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "checkmark.shield").font(.system(size: 28)).foregroundStyle(Palette.secondary)
                    Text("还没有告警记录").font(.system(size: 14, weight: .medium))
                    Text("持续异常时，会自动记下内存状态和当时占用较大的进程。最近 200 次告警保存在本机。")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }.padding(.vertical, 20)
            }
            ForEach(model.incidents.reversed()) { event in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(event.body).fixedSize(horizontal: false, vertical: true)
                        Text("压力\(event.sample.pressure.label) · swap \(formatGiB(event.sample.swapUsed))")
                        ForEach(event.processes) { p in
                            HStack { Text(p.name).lineLimit(1); Spacer(); Text(formatMemory(p.bytes)).monospacedDigit() }
                        }
                        Text("进程为告警附近采样的 RSS 近似值。")
                    }.font(.system(size: 11)).foregroundStyle(Palette.secondary).padding(.vertical, 6)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.time.formatted(date: .abbreviated, time: .standard)).font(.system(size: 10)).foregroundStyle(Palette.secondary)
                        Text(event.title).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider()
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 17) {
            Toggle("异常提醒", isOn: $model.alertsEnabled)
            Toggle("提醒时播放声音", isOn: $model.sound).disabled(!model.alertsEnabled)
            HStack {
                Picker("提醒声音", selection: $model.voiceAlert) {
                    Text("你的录音").tag(true)
                    Text("系统提示音").tag(false)
                }.disabled(!model.sound || !model.alertsEnabled)
                Button(model.voicePlaying ? "停止播放" : "试听语音") { model.previewVoice() }.disabled(model.voiceURL == nil)
            }.controlSize(.small)
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                Label(model.notificationStatus, systemImage: model.notificationAllowed ? "bell.badge" : "bell.slash")
                HStack {
                    if !model.notificationAllowed { Button("允许通知") { model.requestNotifications() } }
                    Button("测试通知") { model.testNotification() }
                    Button("系统设置") { model.openNotificationSettings() }
                }.controlSize(.small)
                if !model.voiceAlert && model.notificationAllowed && !model.notificationSoundAllowed {
                    Text("系统通知声音已关闭，请到系统设置开启“播放通知声音”。")
                        .font(.system(size: 11)).foregroundStyle(Palette.warning)
                }
                Text(model.voiceAlert ? "录音由应用直接播放，受上方声音开关和系统音量控制。专注模式不会自动静音录音。" : "系统提示音受 macOS 通知声音、音量和专注模式影响。")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("提醒条件").font(.system(size: 13, weight: .semibold))
                Text("黄色压力持续 30 秒；红色压力立即提醒。")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                Picker("swap 达到", selection: $model.swapGiB) {
                    ForEach([2.0, 4, 6, 8, 12], id: \.self) { value in Text("\(Int(value)) GiB").tag(value) }
                }
                Picker("磁盘剩余不足", selection: $model.diskGiB) {
                    ForEach([10.0, 20, 30, 50], id: \.self) { value in Text("\(Int(value)) GiB").tag(value) }
                }
                Picker("同类提醒间隔", selection: $model.cooldownMinutes) {
                    ForEach([5.0, 15, 30, 60], id: \.self) { value in Text("\(Int(value)) 分钟").tag(value) }
                }
                Text("swap / 磁盘异常持续 60 秒再提醒；严重时缩短至 30 秒。严重告警可提前升级，同类重复告警受间隔限制。")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }.disabled(!model.alertsEnabled)
            Divider()
            Toggle("登录 Mac 时启动", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
            if model.loginNeedsApproval {
                Text("需要在系统设置 → 通用 → 登录项中允许。")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }
            Text("趋势每分钟记录一次，保留最近 24 小时。告警最多保留 200 条。退出应用后停止监控。")
                .font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 12)).toggleStyle(.checkbox)
    }
}

struct SwapChart: View {
    let history: [Sample]
    let current: Sample
    private var points: [Sample] { history.filter { $0.time > current.time.addingTimeInterval(-3600) } + [current] }
    var body: some View {
        if points.count < 3 {
            VStack(alignment: .leading, spacing: 6) {
                Text("正在积累趋势").font(.system(size: 12))
                Text("约两分钟后显示曲线；当前读数已在监控。")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            Canvas { context, size in
                let maxValue = max(gib, (points.map(\.swapUsed).max() ?? gib) * 1.15)
                let chartWidth = size.width - 38
                let height = size.height - 15
                let start = current.time.addingTimeInterval(-3600)
                func point(_ s: Sample) -> CGPoint {
                    CGPoint(x: max(0, s.time.timeIntervalSince(start) / 3600) * chartWidth,
                            y: height - s.swapUsed / maxValue * (height - 4))
                }
                for fraction in [0.0, 0.5, 1.0] {
                    let y = height * fraction
                    var grid = Path(); grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: chartWidth, y: y))
                    context.stroke(grid, with: .color(.secondary.opacity(0.16)), lineWidth: 0.5)
                }
                var path = Path()
                var last: Sample?
                for sample in points {
                    let p = point(sample)
                    if last == nil || sample.time.timeIntervalSince(last!.time) > 90 { path.move(to: p) }
                    else { path.addLine(to: p) }
                    last = sample
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 1.5, y: height + 7, width: 3, height: 3)), with: .color(sample.pressure.color))
                }
                context.stroke(path, with: .color(.primary.opacity(0.75)), lineWidth: 1.5)
                context.draw(Text(String(format: "%.1f G", maxValue / gib)).font(.system(size: 9)).foregroundColor(Palette.secondary), at: CGPoint(x: chartWidth + 5, y: 4), anchor: .leading)
                context.draw(Text("0").font(.system(size: 9)).foregroundColor(Palette.secondary), at: CGPoint(x: chartWidth + 5, y: height), anchor: .leading)
            }
            .accessibilityLabel("最近一小时 swap 趋势，当前 \(formatGiB(current.swapUsed))，已记录峰值 \(formatGiB(points.map(\.swapUsed).max() ?? 0))")
        }
    }
}
