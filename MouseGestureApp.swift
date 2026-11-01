// MouseGestureApp.swift — double-clickable .app with a menu-bar icon and a
// settings window (pure AppKit, no SwiftUI) for managing custom gesture → key
// mappings, live status, and permissions.
//
// Build target: compile together with Engine.swift into MouseGestureKey.app.

import AppKit
import ApplicationServices

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

func label(_ s: String, secondary: Bool = false) -> NSTextField {
    let f = NSTextField(labelWithString: s)
    if secondary {
        f.font = NSFont.systemFont(ofSize: 11)
        f.textColor = .secondaryLabelColor
    }
    f.lineBreakMode = .byWordWrapping
    f.preferredMaxLayoutWidth = 420
    return f
}

// ---------------------------------------------------------------------------
// Settings window
// ---------------------------------------------------------------------------
class SettingsViewController: NSViewController {
    let controller = GestureController.shared
    var bindingsStack: NSStackView!
    var statusBox: NSTextField!
    var closureSlider: NSSlider!
    var closureVal: NSTextField!
    var roundnessSlider: NSSlider!
    var roundnessVal: NSTextField!
    var debugToggle: NSButton!

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 640))

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        // Live status
        stack.addArrangedSubview(label("实时状态"))
        statusBox = NSTextField(labelWithString: "初始化中…")
        statusBox.font = NSFont.systemFont(ofSize: 11)
        statusBox.textColor = .secondaryLabelColor
        statusBox.lineBreakMode = .byWordWrapping
        statusBox.preferredMaxLayoutWidth = 460
        stack.addArrangedSubview(statusBox)

        // Bindings
        stack.addArrangedSubview(label("手势 → 按键 映射（可添加多个，自定义手势）"))
        bindingsStack = NSStackView()
        bindingsStack.orientation = .vertical
        bindingsStack.spacing = 6
        bindingsStack.alignment = .leading
        stack.addArrangedSubview(bindingsStack)
        let addBtn = NSButton(title: "＋ 添加手势", target: self, action: #selector(addBinding))
        stack.addArrangedSubview(addBtn)
        rebuildBindings()

        // Trigger options
        stack.addArrangedSubview(label("触发方式"))
        debugToggle = NSButton(checkboxWithTitle: "调试模式（在终端输出原始触控数据，便于排查）", target: self, action: #selector(debugChanged))
        debugToggle.state = controller.config.debug ? .on : .off
        stack.addArrangedSubview(debugToggle)

        let holdField = NSTextField()
        holdField.stringValue = String(format: "%.2f", controller.config.holdSeconds)
        holdField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let nf = NumberFormatter(); nf.minimum = 0; nf.maximum = 60; nf.numberStyle = .decimal
        holdField.formatter = nf
        holdField.target = self; holdField.action = #selector(holdChanged)
        let holdRow = NSStackView(views: [label("按住时长（秒，0=瞬时点按）"), holdField])
        holdRow.spacing = 8
        stack.addArrangedSubview(holdRow)

        // Sensitivity
        stack.addArrangedSubview(label("手势灵敏度（数值越大越灵敏，也更容易误触）"))
        closureSlider = NSSlider(value: controller.config.maxClosure, minValue: 0.20, maxValue: 0.80, target: self, action: #selector(closureDone))
        closureSlider.isContinuous = false   // commit only on release (avoids hammering config)
        closureSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        closureVal = label("")
        let closureRow = NSStackView(views: [closureSlider, closureVal]); closureRow.spacing = 8
        stack.addArrangedSubview(closureRow)
        roundnessSlider = NSSlider(value: controller.config.maxRadiusStd, minValue: 0.30, maxValue: 0.90, target: self, action: #selector(roundnessDone))
        roundnessSlider.isContinuous = false
        roundnessSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        roundnessVal = label("")
        let roundRow = NSStackView(views: [roundnessSlider, roundnessVal]); roundRow.spacing = 8
        stack.addArrangedSubview(roundRow)
        closureChanged(); roundnessChanged()

        // Buttons
        let testBtn = NSButton(title: "测试触发（验证按键是否发送）", target: self, action: #selector(testTrigger))
        let revealBtn = NSButton(title: "在访达中显示本 App", target: self, action: #selector(revealInFinder))
        let row1 = NSStackView(views: [testBtn, revealBtn]); row1.spacing = 8
        stack.addArrangedSubview(row1)

        let axPaneBtn = NSButton(title: "打开辅助功能设置", target: self, action: #selector(openAXPrefs))
        let imPaneBtn = NSButton(title: "打开输入监控设置", target: self, action: #selector(openIMPrefs))
        let row2 = NSStackView(views: [axPaneBtn, imPaneBtn]); row2.spacing = 8
        stack.addArrangedSubview(row2)

        let hint = label("授权步骤：① 点上面按钮打开对应设置页 → ② 点左下角 ＋ 把本 App 加进去并打勾 → ③ 菜单栏🖱️退出后重新打开本 App（权限改完要重启才生效）。", secondary: true)
        stack.addArrangedSubview(hint)

        self.view = root
        refreshLive()
    }

    func rebuildBindings() {
        bindingsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for i in 0..<controller.config.bindings.count {
            bindingsStack.addArrangedSubview(bindingRow(index: i))
        }
    }

    func bindingRow(index: Int) -> NSView {
        let b = controller.config.bindings[index]
        let row = NSStackView()
        row.spacing = 6

        let gp = NSPopUpButton()
        for g in GESTURE_TYPES { gp.addItem(withTitle: g.label) }
        if let gi = GESTURE_TYPES.firstIndex(where: { $0.id == b.gesture }) { gp.selectItem(at: gi) }
        gp.tag = index; gp.target = self; gp.action = #selector(gpChanged)

        let kp = NSPopUpButton()
        for p in KEY_PRESETS { kp.addItem(withTitle: p.title) }
        if let ki = KEY_PRESETS.firstIndex(where: { $0.keyCode == b.keyCode && $0.flag == b.flag }) { kp.selectItem(at: ki) }
        kp.tag = index; kp.target = self; kp.action = #selector(kpChanged)

        let en = NSButton(checkboxWithTitle: "启用", target: self, action: #selector(enChanged))
        en.tag = index; en.state = b.enabled ? .on : .off

        let rm = NSButton(title: "删除", target: self, action: #selector(rmPressed))
        rm.tag = index

        row.addArrangedSubview(gp); row.addArrangedSubview(kp); row.addArrangedSubview(en); row.addArrangedSubview(rm)
        return row
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
    @objc func holdChanged(_ s: NSTextField) {
        commit { $0.holdSeconds = Double(s.stringValue) ?? 0 }
    }
    @objc func closureChanged() { closureVal.stringValue = String(format: "闭合容差 %.2f", closureSlider.doubleValue) }
    @objc func roundnessChanged() { roundnessVal.stringValue = String(format: "圆度要求 %.2f", roundnessSlider.doubleValue) }
    @objc func closureDone(_ s: NSSlider) {
        closureVal.stringValue = String(format: "闭合容差 %.2f", s.doubleValue)
        commit { $0.maxClosure = s.doubleValue }
    }
    @objc func roundnessDone(_ s: NSSlider) {
        roundnessVal.stringValue = String(format: "圆度要求 %.2f", s.doubleValue)
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
        let perm = trusted
            ? "辅助功能：已授权 ✅"
            : "辅助功能：未授权 ⚠️ 点『打开辅助功能设置』，在系统设置里点 ＋ 加入本 App 并打勾，再退出重开"
        let frameHint = controller.frameCount > 0
            ? "（在涨 = 手势读取正常，输入监控已生效）"
            : "（若一直不动，可能输入监控未授权或鼠标未连接）"
        statusBox.stringValue = """
        设备：已连接并运行
        已捕获帧数：\(controller.frameCount) \(frameHint)
        最近识别：\(controller.lastGesture)
        \(perm)
        输入监控：请到系统设置确认本 App 已加入并打勾（macOS 不提供读取该状态，App 内无法自动显示对号）
        """
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
        win.styleMask = [.titled, .closable]
        win.title = "鼠标手势按键 - 设置"
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
// Entry point
// ---------------------------------------------------------------------------
@main
final class Launcher: NSObject {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu-bar-only app (no Dock icon)
        app.run()
    }
}
