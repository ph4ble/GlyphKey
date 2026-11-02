// MouseGestureApp.swift — double-clickable .app with a menu-bar icon and a
// settings window (pure AppKit, no SwiftUI) for managing custom gesture → key
// mappings, live status, and permissions.
//
// Build target: compile together with Engine.swift into MouseGestureKey.app.

import AppKit
import ApplicationServices
import ServiceManagement

// Preset keys the user can pick in the settings UI.
let KEY_PRESETS: [(title: String, keyCode: UInt16, flag: String)] = [
    ("右侧 Option (⌥)",   0x3D, "rightOption"),
    ("左侧 Option (⌥)",   0x3A, "leftOption"),
    ("空格 Space",         0x31, ""),
    ("回车 Return",        0x24, ""),
    ("右侧 Control (⌃)",   0x3E, "rightControl"),
    ("左侧 Control (⌃)",   0x3B, "control"),
    ("Command (⌘)",        0x37, "command"),
    ("右侧 Shift (⇧)",    0x3C, "rightShift"),
]

// Text label with full control over size / weight / color. Wraps by word.
func mkLabel(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
             color: NSColor = .labelColor) -> NSTextField {
    let f = NSTextField(labelWithString: s)
    f.font = .systemFont(ofSize: size, weight: weight)
    f.textColor = color
    f.lineBreakMode = .byWordWrapping
    f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return f
}

func hstack(_ views: [NSView], spacing: CGFloat,
            align: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .horizontal
    s.alignment = align
    s.spacing = spacing
    return s
}

func vstack(_ views: [NSView], spacing: CGFloat,
            align: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .vertical
    s.alignment = align
    s.spacing = spacing
    return s
}

func hSeparator() -> NSBox {
    let b = NSBox()
    b.boxType = .separator
    return b
}

// A top-anchored container for the scroll view's document content, so a short
// document sits at the TOP instead of the bottom (AppKit's default).
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// ---------------------------------------------------------------------------
// Settings window
// ---------------------------------------------------------------------------
class SettingsViewController: NSViewController {
    let controller = GestureController.shared
    var bindingsHost: NSStackView!
    var bindingsGrid: NSGridView?
    var debugToggle: NSButton!
    var launchToggle: NSButton!
    var closureSlider: NSSlider!
    var closureVal: NSTextField!
    var roundnessSlider: NSSlider!
    var roundnessVal: NSTextField!
    var deviceVal: NSTextField!
    var frameVal: NSTextField!
    var gestureVal: NSTextField!
    var axVal: NSTextField!
    var imVal: NSTextField!

    // ---- layout helpers -------------------------------------------------
    private func sectionTitle(_ t: String, _ sub: String? = nil) -> NSView {
        let title = mkLabel(t, size: 14, weight: .semibold)
        guard let sub = sub else { return title }
        return vstack([title, mkLabel(sub, size: 11, color: .secondaryLabelColor)], spacing: 3, align: .leading)
    }

    // Add a view that spans the full content width (so separators, sliders and
    // wrapping labels stretch instead of hugging their intrinsic width).
    private func addWide(_ v: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func statusRow(_ key: String, _ value: NSTextField) -> NSView {
        let k = mkLabel(key, size: 12, color: .secondaryLabelColor)
        k.setContentHuggingPriority(.required, for: .horizontal)
        k.setContentCompressionResistancePriority(.required, for: .horizontal)
        k.widthAnchor.constraint(equalToConstant: 86).isActive = true
        return hstack([k, value], spacing: 12, align: .top)
    }

    private func sliderRow(_ title: String, _ slider: NSSlider, _ value: NSTextField) -> NSView {
        let t = mkLabel(title, size: 12)
        t.setContentHuggingPriority(.required, for: .horizontal)
        t.setContentCompressionResistancePriority(.required, for: .horizontal)
        t.widthAnchor.constraint(equalToConstant: 86).isActive = true
        return hstack([t, slider, value], spacing: 12)
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 780))

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        // Flipped document view => short content anchors at the TOP (no big top gap).
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc

        let stack = buildContent()
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -22),
        ])

        self.view = root
        refreshLive()
    }

    // Builds the scrollable content (all sections). Shared by the live window and
    // the --snapshot renderer.
    func buildContent() -> NSStackView {
        let stack = vstack([], spacing: 18, align: .leading)
        // ---- 实时状态 ----
        addWide(sectionTitle("实时状态"), to: stack)
        deviceVal = mkLabel("—", size: 12)
        frameVal = mkLabel("—", size: 12)
        gestureVal = mkLabel("—", size: 12)
        axVal = mkLabel("—", size: 12)
        imVal = mkLabel("—", size: 12)
        addWide(statusRow("设备", deviceVal), to: stack)
        addWide(statusRow("已捕获帧数", frameVal), to: stack)
        addWide(statusRow("最近识别", gestureVal), to: stack)
        addWide(statusRow("辅助功能", axVal), to: stack)
        addWide(statusRow("输入监控", imVal), to: stack)

        // ---- 手势 → 按键映射 ----
        addWide(hSeparator(), to: stack)
        addWide(sectionTitle("手势 → 按键映射", "支持添加多个；画出对应手势即触发所选按键"), to: stack)
        bindingsHost = vstack([], spacing: 10, align: .leading)
        stack.addArrangedSubview(bindingsHost)
        let addBtn = NSButton(title: "＋ 添加手势", target: self, action: #selector(addBinding))
        addBtn.bezelStyle = .rounded
        stack.addArrangedSubview(addBtn)
        rebuildBindings()

        // ---- 触发方式 ----
        addWide(hSeparator(), to: stack)
        addWide(sectionTitle("触发方式"), to: stack)
        debugToggle = NSButton(checkboxWithTitle: "调试模式（记录原始触控数据，便于排查）", target: self, action: #selector(debugChanged))
        debugToggle.state = controller.config.debug ? .on : .off
        stack.addArrangedSubview(debugToggle)

        let holdField = NSTextField()
        holdField.stringValue = String(format: "%.2f", controller.config.holdSeconds)
        holdField.alignment = .right
        holdField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let nf = NumberFormatter(); nf.minimum = 0; nf.maximum = 60; nf.numberStyle = .decimal
        holdField.formatter = nf
        holdField.target = self; holdField.action = #selector(holdChanged)
        stack.addArrangedSubview(hstack([mkLabel("按住时长（秒，0=瞬时点按）", size: 12), holdField], spacing: 10))

        // ---- 启动 ----
        addWide(hSeparator(), to: stack)
        addWide(sectionTitle("启动"), to: stack)
        launchToggle = NSButton(checkboxWithTitle: "开机自动启动（登录后自动在后台运行）", target: self, action: #selector(launchChanged))
        launchToggle.state = launchAtLoginEnabled() ? .on : .off
        stack.addArrangedSubview(launchToggle)

        // ---- 手势灵敏度 ----
        addWide(hSeparator(), to: stack)
        addWide(sectionTitle("手势灵敏度", "数值越大越灵敏，也越容易误触"), to: stack)
        closureSlider = NSSlider(value: controller.config.maxClosure, minValue: 0.20, maxValue: 0.80, target: self, action: #selector(closureDone))
        closureSlider.isContinuous = false
        closureSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        closureSlider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        closureVal = mkLabel("", size: 12); closureVal.alignment = .right
        closureVal.widthAnchor.constraint(equalToConstant: 42).isActive = true
        addWide(sliderRow("闭合容差", closureSlider, closureVal), to: stack)

        roundnessSlider = NSSlider(value: controller.config.maxRadiusStd, minValue: 0.30, maxValue: 0.90, target: self, action: #selector(roundnessDone))
        roundnessSlider.isContinuous = false
        roundnessSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        roundnessSlider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        roundnessVal = mkLabel("", size: 12); roundnessVal.alignment = .right
        roundnessVal.widthAnchor.constraint(equalToConstant: 42).isActive = true
        addWide(sliderRow("圆度要求", roundnessSlider, roundnessVal), to: stack)
        closureChanged(); roundnessChanged()

        // ---- 操作 ----
        addWide(hSeparator(), to: stack)
        addWide(sectionTitle("操作"), to: stack)
        let testBtn = NSButton(title: "测试触发", target: self, action: #selector(testTrigger))
        let revealBtn = NSButton(title: "在访达中显示 App", target: self, action: #selector(revealInFinder))
        stack.addArrangedSubview(hstack([testBtn, revealBtn], spacing: 10))
        let axBtn = NSButton(title: "打开辅助功能设置", target: self, action: #selector(openAXPrefs))
        let imBtn = NSButton(title: "打开输入监控设置", target: self, action: #selector(openIMPrefs))
        stack.addArrangedSubview(hstack([axBtn, imBtn], spacing: 10))

        let hint = mkLabel("授权步骤：① 点上方按钮打开对应设置页 → ② 点左下角 ＋ 把本 App 加入并打勾 → ③ 从菜单栏 🖱️ 退出后重新打开本 App（权限改完要重启才生效）。", size: 11, color: .secondaryLabelColor)
        addWide(hint, to: stack)

        return stack
    }

    func rebuildBindings() {
        bindingsHost.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var rows: [[NSView]] = [[
            mkLabel("手势", size: 11, color: .secondaryLabelColor),
            mkLabel("按键", size: 11, color: .secondaryLabelColor),
            mkLabel("启用", size: 11, color: .secondaryLabelColor),
            mkLabel("", size: 11, color: .secondaryLabelColor),
        ]]
        for i in 0..<controller.config.bindings.count {
            rows.append(bindingCells(index: i))
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .leading
        grid.column(at: 2).xPlacement = .center
        grid.column(at: 3).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        bindingsHost.addArrangedSubview(grid)
        bindingsGrid = grid
    }

    func bindingCells(index: Int) -> [NSView] {
        let b = controller.config.bindings[index]

        let gp = NSPopUpButton()
        for g in GESTURE_TYPES { gp.addItem(withTitle: g.label) }
        if let gi = GESTURE_TYPES.firstIndex(where: { $0.id == b.gesture }) { gp.selectItem(at: gi) }
        gp.tag = index; gp.target = self; gp.action = #selector(gpChanged)
        gp.widthAnchor.constraint(equalToConstant: 148).isActive = true

        let kp = NSPopUpButton()
        for p in KEY_PRESETS { kp.addItem(withTitle: p.title) }
        if let ki = KEY_PRESETS.firstIndex(where: { $0.keyCode == b.keyCode && $0.flag == b.flag }) { kp.selectItem(at: ki) }
        kp.tag = index; kp.target = self; kp.action = #selector(kpChanged)
        kp.widthAnchor.constraint(equalToConstant: 168).isActive = true

        let en = NSButton(checkboxWithTitle: "启用", target: self, action: #selector(enChanged))
        en.tag = index; en.state = b.enabled ? .on : .off

        let rm = NSButton(title: "删除", target: self, action: #selector(rmPressed))
        rm.tag = index; rm.bezelStyle = .rounded
        rm.widthAnchor.constraint(equalToConstant: 52).isActive = true

        return [gp, kp, en, rm]
    }

    private func commit(_ mutate: (inout Config) -> Void) {
        var cfg = controller.config
        mutate(&cfg)
        controller.setConfig(cfg)
        controller.saveConfig()
    }

    @objc func gpChanged(_ s: NSPopUpButton) {
        let i = s.tag
        commit { $0.bindings[i].gesture = GESTURE_TYPES[s.indexOfSelectedItem].id }
    }
    @objc func kpChanged(_ s: NSPopUpButton) {
        let i = s.tag; let p = KEY_PRESETS[s.indexOfSelectedItem]
        commit { $0.bindings[i].keyCode = p.keyCode; $0.bindings[i].flag = p.flag }
    }
    @objc func enChanged(_ s: NSButton) {
        let i = s.tag
        commit { $0.bindings[i].enabled = (s.state == .on) }
    }
    @objc func rmPressed(_ s: NSButton) {
        commit { $0.bindings.remove(at: s.tag) }
        rebuildBindings()
    }
    @objc func addBinding(_ s: Any) {
        commit { $0.bindings.append(Binding(gesture: "circle", keyCode: 0x3D, flag: "rightOption", enabled: true)) }
        rebuildBindings()
    }
    @objc func debugChanged(_ s: NSButton) {
        commit { $0.debug = (s.state == .on) }
    }
    @objc func launchChanged(_ s: NSButton) {
        let want = (s.state == .on)
        let r = setLaunchAtLogin(want)
        if !r.ok {
            s.state = want ? .off : .on
            let alert = NSAlert()
            alert.messageText = "设置开机启动失败"
            alert.informativeText = r.message
            alert.alertStyle = .warning
            alert.runModal()
        } else {
            s.state = launchAtLoginEnabled() ? .on : .off
            if !r.message.isEmpty {
                let alert = NSAlert()
                alert.messageText = "开机启动"
                alert.informativeText = r.message
                alert.alertStyle = .informational
                alert.runModal()
            }
        }
    }
    @objc func holdChanged(_ s: NSTextField) {
        commit { $0.holdSeconds = Double(s.stringValue) ?? 0 }
    }
    @objc func closureChanged() { closureVal.stringValue = String(format: "%.2f", closureSlider.doubleValue) }
    @objc func roundnessChanged() { roundnessVal.stringValue = String(format: "%.2f", roundnessSlider.doubleValue) }
    @objc func closureDone(_ s: NSSlider) {
        closureVal.stringValue = String(format: "%.2f", s.doubleValue)
        commit { $0.maxClosure = s.doubleValue }
    }
    @objc func roundnessDone(_ s: NSSlider) {
        roundnessVal.stringValue = String(format: "%.2f", s.doubleValue)
        commit { $0.maxRadiusStd = s.doubleValue }
    }

    @objc func testTrigger(_ s: Any) { controller.testTrigger() }
    @objc func revealInFinder(_ s: Any) {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
    @objc func openAXPrefs(_ s: Any) { openAccessibilityPrefs() }
    @objc func openIMPrefs(_ s: Any) { openInputMonitoringPrefs() }

    // Called by the app delegate on live events.
    func refreshLive() {
        let trusted = AXIsProcessTrusted()

        if controller.deviceConnected {
            deviceVal.stringValue = controller.deviceBuiltIn
                ? "已连接（内建设备，可能不是 Magic Mouse）"
                : "已连接（外部 Magic Mouse）"
        } else {
            deviceVal.stringValue = "未连接 — 请连接 Magic Mouse 后用菜单栏『重新连接设备』"
        }

        frameVal.stringValue = controller.frameCount > 0
            ? "\(controller.frameCount)（在涨 = 手势读取正常）"
            : "0（一直为 0 说明权限未生效：请退出本 App 重新打开）"

        gestureVal.stringValue = controller.lastGesture

        if trusted {
            axVal.stringValue = "已授权 ✓"
            axVal.textColor = .systemGreen
        } else {
            axVal.stringValue = "未授权 — 点下方『打开辅助功能设置』把本 App 加入并打勾，再退出重开"
            axVal.textColor = .systemOrange
        }

        imVal.stringValue = "需在系统设置中确认已加入并打勾（macOS 不提供读取，App 内无法自动显示对号）"
    }
}

// ---------------------------------------------------------------------------
// App delegate: menu bar + window management
// ---------------------------------------------------------------------------
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let controller = GestureController.shared
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var settingsWindow: NSWindow?
    weak var settingsVC: SettingsViewController?
    var statusText = "初始化中…"
    private var frameTick = 0
    private var menuOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        controller.onFrame = { [weak self] in
            guard let self = self else { return }
            self.frameTick += 1
            if self.frameTick % 15 == 0 { self.settingsVC?.refreshLive() }
        }
        controller.onGesture = { [weak self] g in
            self?.statusText = "最近识别：\(g)"
            self?.refreshMenu()
            self?.settingsVC?.refreshLive()
        }
        controller.onFire = { [weak self] kc, g in
            self?.statusText = "刚刚触发：\(g)"
            self?.refreshMenu()
            self?.settingsVC?.refreshLive()
        }
        controller.onStatus = { [weak self] s in
            guard let self = self else { return }
            self.statusText = s
            if !self.menuOpen { self.refreshMenu() }
            self.settingsVC?.refreshLive()
        }

        controller.start()
        // Auto-open settings so the user can see the app is running and grant permissions.
        openSettings()

        // Periodically refresh the live status so permission checkmarks and the device
        // state update on their own (e.g. the Accessibility ✓ appears right after the
        // user grants it in System Settings, without needing to click "测试触发").
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.settingsVC?.refreshLive()
        }
    }

    func setupStatusItem() {
        if let btn = statusItem.button {
            btn.title = "🖱️"
            btn.toolTip = "鼠标手势按键"
        }
        refreshMenu()
    }

    func refreshMenu() {
        let menu = NSMenu()
        let s = NSMenuItem(title: "状态：\(statusText)", action: nil, keyEquivalent: "")
        s.isEnabled = false
        menu.addItem(s)
        menu.addItem(.separator())

        let setM = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        setM.target = self
        menu.addItem(setM)

        let testM = NSMenuItem(title: "测试触发", action: #selector(testTrigger), keyEquivalent: "")
        testM.target = self
        menu.addItem(testM)

        let reconM = NSMenuItem(title: "重新连接设备", action: #selector(reconnect), keyEquivalent: "")
        reconM.target = self
        menu.addItem(reconM)

        menu.addItem(.separator())

        let quitM = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitM.target = self
        menu.addItem(quitM)

        statusItem.menu = menu
        menu.delegate = self
    }

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }
    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        refreshMenu()   // refresh once after closing so the status line is current
    }

    @objc func openSettings() {
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let vc = SettingsViewController()
        settingsVC = vc
        let win = NSWindow(contentViewController: vc)
        win.styleMask = [.titled, .closable, .resizable]
        win.title = "鼠标手势按键 - 设置"
        win.setContentSize(NSSize(width: 560, height: 780))
        win.minSize = NSSize(width: 520, height: 420)
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = win
    }

    @objc func testTrigger() { controller.testTrigger() }

    @objc func reconnect() {
        controller.stop()
        controller.setConfig(Config.load())
        controller.start()
    }

    @objc func quit() {
        controller.stop()
        NSApp.terminate(nil)
    }
}

// ---------------------------------------------------------------------------
// Permission helpers
// ---------------------------------------------------------------------------
func openAccessibilityPrefs() {
    let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.security")!
    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") ?? fallback
    NSWorkspace.shared.open(url)
}

func openInputMonitoringPrefs() {
    let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.security")!
    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_InputMonitoring") ?? fallback
    NSWorkspace.shared.open(url)
}

// ---------------------------------------------------------------------------
// Launch at login
// ---------------------------------------------------------------------------
private let launchAgentLabel = "com.user.mousegesturekey"

private var launchAgentURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
}

// True if the app is currently set to launch at login (either mechanism).
func launchAtLoginEnabled() -> Bool {
    if #available(macOS 13.0, *) {
        if SMAppService.mainApp.status == .enabled { return true }
    }
    return FileManager.default.fileExists(atPath: launchAgentURL.path)
}

// Enable/disable launch-at-login. Prefers the modern SMAppService (shows up in
// System Settings → General → Login Items); falls back to a per-user LaunchAgent
// when SMAppService is unavailable or refuses (e.g. app not in /Applications).
@discardableResult
func setLaunchAtLogin(_ enabled: Bool) -> (ok: Bool, message: String) {
    if #available(macOS 13.0, *) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            // register() can leave the item "pending approval"; report it.
            if enabled && SMAppService.mainApp.status == .requiresApproval {
                return (true, "已登记，需在『系统设置 → 通用 → 登录项』中允许本 App")
            }
            return (true, "")
        } catch {
            if !enabled { return (true, "") }   // nothing to unregister
            // fall through to LaunchAgent fallback
        }
    }
    return setLaunchAgent(enabled)
}

private func setLaunchAgent(_ enabled: Bool) -> (ok: Bool, message: String) {
    let fm = FileManager.default
    if enabled {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
        guard !exe.isEmpty else { return (false, "无法定位可执行文件") }
        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
            return (false, "无法生成启动项配置")
        }
        do {
            try fm.createDirectory(at: launchAgentURL.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try data.write(to: launchAgentURL)
        } catch {
            return (false, error.localizedDescription)
        }
        runLaunchctl(["load", "-w", launchAgentURL.path])
        return (true, "")
    } else {
        if fm.fileExists(atPath: launchAgentURL.path) {
            runLaunchctl(["unload", "-w", launchAgentURL.path])
            try? fm.removeItem(at: launchAgentURL)
        }
        return (true, "")
    }
}

private func runLaunchctl(_ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    try? p.run()
    p.waitUntilExit()
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------
@main
final class Launcher: NSObject {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // menu-bar-only app (no Dock icon)

        // Dev helper: render the settings window to a PNG and exit, so the layout
        // can be inspected without a screen capture.
        if CommandLine.arguments.contains("--snapshot") {
            let vc = SettingsViewController()
            let stack = vc.buildContent()
            vc.refreshLive()
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 200))
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            stack.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: host.topAnchor, constant: 22),
                stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 22),
                stack.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -22),
            ])
            host.layoutSubtreeIfNeeded()
            host.frame.size.height = stack.fittingSize.height + 44
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: "/tmp/mgk_ui.png"))
                }
            }
            exit(0)
        }

        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
