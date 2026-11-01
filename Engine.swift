// Engine.swift — shared core for MouseGestureKey (used by both the CLI and the .app)
//
// Maps custom gestures drawn on an Apple Magic Mouse to keyboard keys.
//   1. Loads the private MultitouchSupport.framework at runtime via dlopen/dlsym
//      (no link-time dependency, so it survives framework layout changes).
//   2. Enumerates multitouch devices and picks the EXTERNAL one (the Magic Mouse;
//      built-in trackpads are skipped).
//   3. Registers a contact-frame callback that receives raw touch frames.
//   4. Tracks single-finger "strokes". When a stroke ends, it extracts the
//      normalized (x,y) coordinates (trying many byte offsets so it works regardless
//      of the exact touch-struct layout on your macOS version) and classifies the
//      gesture: circle / swipe (←↑↓→) / tap / double-tap.
//   5. On a recognized gesture, it posts the configured keyboard event via CoreGraphics.

import Foundation
import CoreGraphics
import CoreFoundation
import Dispatch

// ---------------------------------------------------------------------------
// Config & bindings
// ---------------------------------------------------------------------------
let GESTURE_TYPES: [(id: String, label: String)] = [
    ("circle",     "画圈 Circle"),
    ("swipeLeft",  "向左滑 ←"),
    ("swipeRight", "向右滑 →"),
    ("swipeUp",    "向上滑 ↑"),
    ("swipeDown",  "向下滑 ↓"),
    ("tap",        "点按 Tap"),
    ("doubleTap",  "双击 Double Tap"),
]

struct Binding: Codable {
    var gesture: String
    var keyCode: UInt16
    var flag: String
    var enabled: Bool
}

struct Config: Codable {
    var bindings: [Binding]
    var debug: Bool
    var holdSeconds: Double
    // Gesture sensitivity.
    var minAngularCoverage: Double   // radians of the circle that must be traced
    var maxRadiusStd: Double         // allowed radius variation (std/mean)
    var maxClosure: Double           // how close the end must return to the start

    static func `default`() -> Config {
        Config(
            bindings: [
                Binding(gesture: "circle",     keyCode: 0x3D, flag: "rightOption", enabled: true),
                Binding(gesture: "swipeRight", keyCode: 0x31, flag: "",           enabled: false),
                Binding(gesture: "swipeLeft",  keyCode: 0x24, flag: "",           enabled: false),
                Binding(gesture: "tap",        keyCode: 0x37, flag: "command",    enabled: false),
            ],
            debug: false,
            holdSeconds: 0,
            minAngularCoverage: 3.8,
            maxRadiusStd: 0.6,
            maxClosure: 0.45
        )
    }

    static func load() -> Config {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".mousegesturekey.json")
        guard let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(Config.self, from: data) else { return Config.default() }
        return c
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".mousegesturekey.json")
            try? data.write(to: url)
        }
    }
}

// CGEventFlags raw bitmasks (kCGEventFlagMask*). The physical left/right key
// is selected by keyCode; the mask just marks the modifier family.
func cgFlags(for flag: String) -> CGEventFlags {
    let raw: UInt64
    switch flag {
    case "rightOption", "leftOption", "option": raw = 1 << 19   // alternate (Option)
    case "rightControl", "control":            raw = 1 << 18   // control
    case "rightShift", "shift":               raw = 1 << 17   // shift
    case "command", "rightCommand":           raw = 1 << 20   // command
    default:                                  raw = 0
    }
    return CGEventFlags(rawValue: raw)
}

// ---------------------------------------------------------------------------
// MultitouchSupport (private framework) — runtime bindings
// Wrapped in a namespace so Engine.swift stays declaration-only (required when
// the same file is compiled together with a main file that has top-level code).
// ---------------------------------------------------------------------------
typealias MTDeviceRef = OpaquePointer
// NOTE: the real callback returns Int32 (Karabiner-Elements mirrors this and returns 0).
// A `-> Void` binding is an ABI mismatch with the framework and must be avoided.
typealias MTCallback = @convention(c) (MTDeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

enum Multitouch {
    static let fwPath = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    static let fw: UnsafeMutableRawPointer = {
        setvbuf(stderr, nil, _IONBF, 0)   // unbuffered stderr: logs show immediately
        guard let h = dlopen(fwPath, RTLD_LAZY) else {
            fputs("FATAL: cannot dlopen \(fwPath): \(String(cString: dlerror()))\n", stderr)
            exit(1)
        }
        return h
    }()

    static func sym<T>(_ name: String) -> T {
        guard let p = dlsym(fw, name) else {
            fputs("FATAL: missing symbol \(name)\n", stderr); exit(1)
        }
        return unsafeBitCast(p, to: T.self)
    }

    static let fnCreateList:     @convention(c) () -> CFArray?                 = sym("MTDeviceCreateList")
    static let fnCreateDefault:  @convention(c) () -> MTDeviceRef?             = sym("MTDeviceCreateDefault")
    static let fnIsBuiltIn:      @convention(c) (MTDeviceRef?) -> Bool          = sym("MTDeviceIsBuiltIn")
    static let fnStart:          @convention(c) (MTDeviceRef?, Int32) -> Int32  = sym("MTDeviceStart")
    // Karabiner-Elements calls MTDeviceStop(device, 0) — two args. Match it.
    static let fnStop:           @convention(c) (MTDeviceRef?, Int32) -> Void  = sym("MTDeviceStop")
    static let fnRegister:       @convention(c) (MTDeviceRef?, MTCallback?) -> Void = sym("MTRegisterContactFrameCallback")
    static let fnUnregister:     @convention(c) (MTDeviceRef?) -> Void         = sym("MTUnregisterContactFrameCallback")

    // The callback must return Int32 (0). The framework expects a return value.
    static let cCallback: MTCallback = { device, touches, n, ts, frame in
        GestureController.shared.handleFrame(touches: touches, n: n, ts: ts)
        return 0
    }
}

// ---------------------------------------------------------------------------
// Gesture controller
// ---------------------------------------------------------------------------
final class GestureController {
    static let shared = GestureController()
    private let lock = NSLock()
    private var strokeRaw: [Data] = []
    private var lastTouchTS: Double = -10
    private var lastEndTS: Double = -10
    private var strokeStart: Double = 0
    private var lastFireTS: Double = -10
    private var device: MTDeviceRef?
    private var devices: [MTDeviceRef] = []
    private var running = false
    private var pendingTap: DispatchWorkItem?

    var config: Config
    var onStatus: ((String) -> Void)?
    var onFrame: (() -> Void)?
    var onGesture: ((String) -> Void)?
    var onFire: ((UInt16, String) -> Void)?

    var frameCount: Int = 0
    var lastGesture: String = "—"
    var deviceConnected: Bool = false
    var deviceBuiltIn: Bool = false
    private var dumpCount: Int = 0
    static var debugFP: UnsafeMutablePointer<FILE>? = nil

    init() { self.config = Config.load() }

    func setConfig(_ c: Config) {
        lock.lock(); config = c; lock.unlock()
    }

    func saveConfig() { config.save() }

    func start() {
        if config.debug {
            GestureController.debugFP = fopen("/tmp/mgk_app.log", "w")
            dumpCount = 60   // dump raw fields for the first 60 frames to locate x/y
            if let fp = GestureController.debugFP {
                let exe = CommandLine.arguments.first ?? "?"
                let pid = ProcessInfo.processInfo.processIdentifier
                fputs(String(format: "=== start pid=%d exe=%s\n", pid, (exe as NSString).utf8String ?? ""), fp)
                fflush(fp)
            }
        }
        lock.lock()
        guard !running else { lock.unlock(); return }
        var started: [MTDeviceRef] = []
        if let list = Multitouch.fnCreateList() {
            let count = CFArrayGetCount(list)
            for i in 0..<count {
                let dev = unsafeBitCast(CFArrayGetValueAtIndex(list, i), to: MTDeviceRef?.self)
                if let dev = dev {
                    Multitouch.fnRegister(dev, Multitouch.cCallback)
                    let rc = Multitouch.fnStart(dev, 0)
                    let b = Multitouch.fnIsBuiltIn(dev)
                    fputs(String(format: "started dev#%d builtIn=%d rc=%d\n", i, b ? 1 : 0, rc), stderr)
                    if let fp = GestureController.debugFP {
                        fputs(String(format: "started dev#%d builtIn=%d rc=%d\n", i, b ? 1 : 0, rc), fp); fflush(fp)
                    }
                    started.append(dev)
                }
            }
        }
        if started.isEmpty {
            if let d = Multitouch.fnCreateDefault() {
                Multitouch.fnRegister(d, Multitouch.cCallback)
                let rc = Multitouch.fnStart(d, 0)
                fputs(String(format: "started default dev rc=%d\n", rc), stderr)
                started.append(d)
            }
        }
        guard !started.isEmpty else {
            deviceConnected = false
            lock.unlock()
            DispatchQueue.main.async { self.onStatus?("未找到鼠标设备（请连接 Magic Mouse 后点『重新连接设备』）") }
            return
        }
        devices = started
        device = started.first
        running = true
        deviceConnected = true
        deviceBuiltIn = Multitouch.fnIsBuiltIn(device!)
        let bi = deviceBuiltIn
        fputs(String(format: "DEVICE connected (%d device(s)) builtIn=%d\n", started.count, bi ? 1 : 0), stderr)
        lock.unlock()
        DispatchQueue.main.async { self.onStatus?("已连接设备，运行中（builtIn=\(bi ? 1 : 0)）\n帧数：0") }
    }

    func stop() {
        lock.lock()
        for d in devices { Multitouch.fnUnregister(d); Multitouch.fnStop(d, 0) }
        devices.removeAll()
        device = nil
        running = false
        deviceConnected = false
        lock.unlock()
        if GestureController.debugFP != nil {
            fclose(GestureController.debugFP)
            GestureController.debugFP = nil
        }
    }

    func handleFrame(touches: UnsafeMutableRawPointer?, n: Int32, ts: Double) {
        lock.lock(); defer { lock.unlock() }
        if config.debug {
            let line = String(format: "cb n=%d\n", n)
            fputs(line, stderr)
            if let fp = GestureController.debugFP { fputs(line, fp); fflush(fp) }
        }
        guard n >= 0, n <= 20 else { return }
        let num = Int(n)
        let now = CFAbsoluteTimeGetCurrent()
        if num >= 1 {
            guard let t = touches else { return }
            if strokeRaw.isEmpty {
                strokeRaw.removeAll()
                strokeStart = now
            } else if (now - lastEndTS) > 0.25 {
                strokeRaw.removeAll()
                strokeStart = now
            }
            let bytes = Data(bytes: t, count: 256)
            strokeRaw.append(bytes)
            lastTouchTS = now
            frameCount += 1
            if frameCount % 10 == 0 { let fc = frameCount; DispatchQueue.main.async { self.onFrame?(); self.onStatus?(self.statusLine(frames: fc)) } }
        if config.debug {
            if dumpCount > 0 {
                dumpCount -= 1
                var s = String(format: "frame n=%d pts=%d:", num, strokeRaw.count)
                for off in stride(from: 0, through: 248, by: 4) {
                    s += String(format: " %d:%.3f", off, readFloat(bytes, off))
                }
                s += "\n"
                fputs(s, stderr)
                if let fp = GestureController.debugFP { fputs(s, fp); fflush(fp) }
            }
        }
        } else {
            if !strokeRaw.isEmpty && (now - lastTouchTS) > 0.12 {
                finalizeStroke()
                lastEndTS = now
            }
        }
    }

    private func statusLine(frames: Int) -> String {
        return "运行中（帧数：\(frames)）\n最近识别：\(lastGesture)"
    }

    private func finalizeStroke() {
        let raw = strokeRaw
        strokeRaw.removeAll()
        if config.debug {
            let line = String(format: "finalize raw.count=%d\n", raw.count)
            fputs(line, stderr)
            if let fp = GestureController.debugFP { fputs(line, fp); fflush(fp) }
        }
        guard raw.count >= 2 else { return }
        guard let pts = extractPoints(raw) else { return }
        let duration = CFAbsoluteTimeGetCurrent() - strokeStart
        guard let name = classify(pts, duration: duration) else { return }
        lastGesture = name
        DispatchQueue.main.async { self.onGesture?(name) }
        if name == "tap" {
            handleTap()
        } else {
            fireGesture(name)
        }
    }

    // Locate the (x, y) float pair inside the touch struct by scanning every 4-byte
    // offset. We pick the pair that forms the smallest, finite, non-degenerate 2D
    // bounding box — that is almost always the real normalized touch coordinates
    // regardless of the exact struct layout on this macOS version. (The gesture
    // math below re-normalizes by max(w,h) anyway, so the absolute scale is moot.)
    private func extractPoints(_ raw: [Data]) -> [(Float, Float)]? {
        let len = raw.first?.count ?? 0
        guard len >= 12 else { return nil }
        var best: (off: Int, w: Float, h: Float)? = nil
        var near: (off: Int, w: Float, h: Float)? = nil
        for off in stride(from: 0, through: len - 8, by: 4) {
            var xs: [Float] = [], ys: [Float] = []
            var ok = true
            for d in raw {
                let x = readFloat(d, off)
                let y = readFloat(d, off + 4)
                if !x.isFinite || !y.isFinite || abs(x) > 1e6 || abs(y) > 1e6 { ok = false; break }
                xs.append(x); ys.append(y)
            }
            if !ok { continue }
            let w = xs.max()! - xs.min()!, h = ys.max()! - ys.min()!
            if near == nil || (w + h) < (near!.w + near!.h) { near = (off, w, h) }
            if w > 0.02, h > 0.02 {
                if best == nil || (w + h) < (best!.w + best!.h) { best = (off, w, h) }
            }
        }
        if config.debug {
            if let b = best {
                let line = String(format: "extract BEST off=%d w=%.3f h=%.3f\n", b.off, b.w, b.h)
                fputs(line, stderr)
                if let fp = GestureController.debugFP { fputs(line, fp); fflush(fp) }
            } else {
                let n = near.map { String(format: "off=%d w=%.4f h=%.4f", $0.off, $0.w, $0.h) } ?? "none"
                let line = String(format: "extract NONE near=%@\n", n)
                fputs(line, stderr)
                if let fp = GestureController.debugFP { fputs(line, fp); fflush(fp) }
            }
        }
        guard let b = best else { return nil }
        var pts: [(Float, Float)] = []
        for d in raw { pts.append((readFloat(d, b.off), readFloat(d, b.off + 4))) }
        return pts
    }

    private func classify(_ pts: [(Float, Float)], duration: Double) -> String? {
        let xs = pts.map { $0.0 }, ys = pts.map { $0.1 }
        let minX = xs.min()!, minY = ys.min()!
        let w = xs.max()! - minX, h = ys.max()! - minY
        let norm = pts.map { (($0.0 - minX) / max(w, 1e-6), ($0.1 - minY) / max(h, 1e-6)) }

        let cx = norm.map { $0.0 }.reduce(0, +) / Float(norm.count)
        let cy = norm.map { $0.1 }.reduce(0, +) / Float(norm.count)
        var radii: [Float] = [], angles: [Float] = []
        for p in norm { radii.append(hypot(p.0 - cx, p.1 - cy)); angles.append(atan2(p.1 - cy, p.0 - cx)) }
        let meanR = radii.reduce(0, +) / Float(radii.count)
        var sweep: Float = 0
        for i in 1..<angles.count {
            var d = angles[i] - angles[i - 1]
            while d > .pi { d -= 2 * .pi }
            while d < -.pi { d += 2 * .pi }
            sweep += abs(d)
        }
        let variance = radii.reduce(0) { $0 + ($1 - meanR) * ($1 - meanR) } / Float(radii.count)
        let std = sqrt(variance)
        let first = norm.first!, last = norm.last!
        let dlast = hypot(last.0 - first.0, last.1 - first.1)
        let netDx = last.0 - first.0, netDy = last.1 - first.1
        let netDist = hypot(netDx, netDy)
        let path = pathLength(norm)
        // Straightness: 1.0 = perfectly straight drag, ~0 = begins and ends near same point.
        let straight = path > 1e-4 ? netDist / path : 0

        if config.debug {
            fputs(String(format: "classify dur=%.2f w=%.2f h=%.2f sweep=%.2f std=%.2f dlast=%.2f net=%.2f straight=%.2f\n",
                         duration, w, h, sweep, std / meanR, dlast, netDist, straight), stderr)
        }

        // Tap: short, tiny movement.
        if duration < 0.35, w < 0.18, h < 0.18 { return "tap" }
        // Circle: most of the loop traced, returns near start, roughly constant radius.
        if meanR > 0.1, std / meanR < Float(config.maxRadiusStd),
           sweep > Float(config.minAngularCoverage), dlast < Float(config.maxClosure) * meanR {
            return "circle"
        }
        // Swipe: a fairly straight drag with significant net movement.
        if netDist > 0.12, straight > 0.75 {
            if abs(netDx) > abs(netDy) { return netDx > 0 ? "swipeRight" : "swipeLeft" }
            return netDy > 0 ? "swipeDown" : "swipeUp"
        }
        return nil
    }

    private func pathLength(_ pts: [(Float, Float)]) -> Float {
        var l: Float = 0
        for i in 1..<pts.count { l += hypot(pts[i].0 - pts[i - 1].0, pts[i].1 - pts[i - 1].1) }
        return l
    }

    private func handleTap() {
        if let pending = pendingTap {
            pending.cancel(); pendingTap = nil
            fireGesture("doubleTap")
        } else {
            let item = DispatchWorkItem { [weak self] in
                self?.pendingTap = nil
                self?.fireGesture("tap")
            }
            pendingTap = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
        }
    }

    // Fire the first enabled binding matching the gesture.
    private func fireGesture(_ name: String) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastFireTS > 0.25 else { return }
        guard let b = config.bindings.first(where: { $0.enabled && $0.gesture == name }) else { return }
        lastFireTS = now

        let keyCode = b.keyCode
        let flags = cgFlags(for: b.flag)
        let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)!
        down.flags = flags
        down.post(tap: .cghidEventTap)
        if config.holdSeconds > 0 {
            Thread.sleep(forTimeInterval: config.holdSeconds)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)!
            up.flags = flags
            up.post(tap: .cghidEventTap)
        } else {
            let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)!
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
        fputs(String(format: "FIRED gesture=%@ keyCode=%u flag=%@\n", name, keyCode, b.flag), stderr)
        DispatchQueue.main.async { self.onFire?(keyCode, name) }
    }

    // Test helper: fire the first enabled binding directly (for the UI "test" button).
    func testTrigger() {
        if let b = config.bindings.first(where: { $0.enabled }) {
            fireGesture(b.gesture)
        }
    }

    static func runSelfTest() {
        func gen(_ n: Int, _ span: Double) -> [(Float, Float)] {
            var p: [(Float, Float)] = []
            for i in 0..<n {
                let a = Float(Double(i) / Double(n) * span)
                p.append((0.5 + 0.3 * cos(a), 0.5 + 0.3 * sin(a)))
            }
            return p
        }
        let c = GestureController.shared
        let full = gen(30, 2 * Double.pi)
        let arc = gen(20, Double.pi)
        var line: [(Float, Float)] = []
        for i in 0..<30 { line.append((Float(0.1 + 0.8 * Double(i) / 29), 0.5)) }
        let r1 = c.classify(full, duration: 1.0)
        let r2 = c.classify(arc, duration: 0.7)
        let r3 = c.classify(line, duration: 0.5)
        print("selftest full-circle => \(r1 == "circle" ? "circle ✓" : "\(String(describing: r1)) ✗") (expect circle)")
        print("selftest half-arc    => \(r2 == nil ? "nil ✓" : "\(String(describing: r2)) ✗") (expect nil)")
        let r3ok = (r3 == "swipeRight" || r3 == "swipeLeft")
        print("selftest line        => \(r3ok ? "\(r3!) ✓" : "\(String(describing: r3)) ✗") (expect a swipe)")
        let ok = r1 == "circle" && r2 == nil && r3ok
        print(ok ? "SELFTEST PASS" : "SELFTEST FAIL")
    }
}

// Alignment-safe little-endian float read from a Data byte range.
func readFloat(_ d: Data, _ off: Int) -> Float {
    guard off + 4 <= d.count else { return .nan }
    let b = [UInt8](d.subdata(in: off..<(off + 4)))
    let u = UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    return Float(bitPattern: u)
}
