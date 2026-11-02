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
            maxRadiusStd: 0.9,
            maxClosure: 0.35
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
    private var finalizeTimer: Timer?
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
            dumpCount = 800  // dump raw fields for the first 800 frames to locate x/y
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
                    let b = Multitouch.fnIsBuiltIn(dev)
                    if b {
                        // Skip built-in trackpads — we only want the EXTERNAL device
                        // (the Magic Mouse). Mixing built-in touches corrupts the stroke.
                        fputs(String(format: "skip built-in dev#%d\n", i), stderr)
                        if let fp = GestureController.debugFP {
                            fputs(String(format: "skip built-in dev#%d\n", i), fp); fflush(fp)
                        }
                        continue
                    }
                    Multitouch.fnRegister(dev, Multitouch.cCallback)
                    let rc = Multitouch.fnStart(dev, 0)
                    fputs(String(format: "started dev#%d builtIn=0 rc=%d\n", i, rc), stderr)
                    if let fp = GestureController.debugFP {
                        fputs(String(format: "started dev#%d builtIn=0 rc=%d\n", i, rc), fp); fflush(fp)
                    }
                    started.append(dev)
                }
            }
        }
        if started.isEmpty {
            // No external device found: fall back to the system default (last resort).
            if let d = Multitouch.fnCreateDefault() {
                Multitouch.fnRegister(d, Multitouch.cCallback)
                let rc = Multitouch.fnStart(d, 0)
                fputs(String(format: "started default dev rc=%d\n", rc), stderr)
                if let fp = GestureController.debugFP {
                    fputs(String(format: "started default dev rc=%d\n", rc), fp); fflush(fp)
                }
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
        finalizeTimer?.invalidate(); finalizeTimer = nil
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
            // A real touch arrived: cancel any pending end-of-stroke finalize.
            finalizeTimer?.invalidate(); finalizeTimer = nil
            guard let t = touches else { return }
            if strokeRaw.isEmpty {
                strokeRaw.removeAll()
                strokeStart = now
            } else if (now - lastTouchTS) > 0.5 {
                // A long pause since the previous frame => this is a NEW stroke.
                // NOTE: must compare against lastTouchTS (updated every frame), NOT
                // lastEndTS (only updated at finalize) — the latter is stale during a
                // continuous stroke and would wipe the buffer on every single frame.
                strokeRaw.removeAll()
                strokeStart = now
            }
            let bytes = Data(bytes: t, count: 256)
            strokeRaw.append(bytes)
            lastTouchTS = now
            frameCount += 1
            if frameCount % 10 == 0 { let fc = frameCount; DispatchQueue.main.async { self.onFrame?(); self.onStatus?(self.statusLine(frames: fc)) } }
            if config.debug && dumpCount > 0 {
                dumpCount -= 1
                let dumpOffsets = [8,12,20,24,28,32,36,40,44,48,56,60,64,68,72,76,80,92,128,132,136,140,144,156,160,164,168,172,176,188]
                var s = String(format: "frame n=%d pts=%d:", num, strokeRaw.count)
                for off in dumpOffsets { s += String(format: " %d:%.3f", off, readFloat(bytes, off)) }
                s += "\n"
                fputs(s, stderr)
                if let fp = GestureController.debugFP { fputs(s, fp); fflush(fp) }
            }
        } else {
            // Touch ended. Schedule finalize 0.12s later so it fires even if the
            // framework stops calling the callback after the lift.
            if !strokeRaw.isEmpty && finalizeTimer == nil {
                finalizeTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
                    self?.finalizeTimer = nil
                    self?.finalizeStroke()
                }
            }
        }
    }

    private func statusLine(frames: Int) -> String {
        return "运行中（帧数：\(frames)）\n最近识别：\(lastGesture)"
    }

    private func finalizeStroke() {
        let raw = strokeRaw
        strokeRaw.removeAll()
        lastEndTS = CFAbsoluteTimeGetCurrent()
        if config.debug {
            let line = String(format: "finalize raw.count=%d\n", raw.count)
            fputs(line, stderr)
            if let fp = GestureController.debugFP { fputs(line, fp); fflush(fp) }
            dumpStrokeDiagnostics(raw)
        }
        guard raw.count >= 2 else { return }
        guard let pts = extractPoints(raw) else {
            if config.debug {
                let line = "  extractPoints -> nil\n"
                fputs(line, stderr)
                if let fp = GestureController.debugFP { fputs(line, fp); fflush(fp) }
            }
            return
        }
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

    // When debugging, dump the top offset pairs (by bounding-box area) AND a set of
    // known candidate offsets, each with its value range and a downsampled trajectory.
    // This makes the true normalized-position offset discoverable directly from the log.
    private func dumpStrokeDiagnostics(_ raw: [Data]) {
        let len = raw.first?.count ?? 0
        guard len >= 8, raw.count >= 3 else { return }

        func traj(_ a: Int, _ b: Int, _ maxPts: Int = 24) -> String {
            let step = max(1, raw.count / maxPts)
            var s = ""
            for i in stride(from: 0, to: raw.count, by: step) {
                s += String(format: " (%.2f,%.2f)", readFloat(raw[i], a), readFloat(raw[i], b))
            }
            return s
        }

        // All valid offset pairs (finite, not huge) grouped by area.
        var cands: [(a: Int, b: Int, w: Float, h: Float, lo: Float, hi: Float)] = []
        for a in stride(from: 0, through: len - 8, by: 4) {
            for b in stride(from: a + 4, through: len - 4, by: 4) {
                var xs: [Float] = [], ys: [Float] = []
                var ok = true
                for d in raw {
                    let x = readFloat(d, a), y = readFloat(d, b)
                    if !x.isFinite || !y.isFinite || abs(x) > 1e6 || abs(y) > 1e6 { ok = false; break }
                    xs.append(x); ys.append(y)
                }
                if !ok { continue }
                let w = xs.max()! - xs.min()!, h = ys.max()! - ys.min()!
                guard w > 0.02, h > 0.02, w < 100, h < 100 else { continue }
                let lo = min(xs.min()!, ys.min()!), hi = max(xs.max()!, ys.max()!)
                cands.append((a, b, w, h, lo, hi))
            }
        }
        cands.sort { ($0.w * $0.h) > ($1.w * $1.h) }

        var s = String(format: "  stroke n=%d top8 by area:\n", raw.count)
        for c in cands.prefix(8) {
            s += String(format: "    (%d,%d) w=%.2f h=%.2f range[%.2f,%.2f]%@\n",
                        c.a, c.b, c.w, c.h, c.lo, c.hi, traj(c.a, c.b))
        }
        // Also always show a fixed set of known/likely position offsets.
        s += "  known offsets:\n"
        for (a, b) in [(32,36),(20,24),(40,44),(48,52),(48,92),(60,64),(68,72),(68,92)] {
            s += String(format: "    (%d,%d)%@\n", a, b, traj(a, b))
        }
        // Raw per-frame values for real multi-frame strokes (complete data to pin
        // down the true position offset from a single clean gesture).
        if raw.count <= 80 {
            s += "  raw frames:\n"
            for (i, d) in raw.enumerated() {
                var line = String(format: "    f%d:", i)
                for off in [8,12,20,24,28,32,36,40,44,48,52,56,60,64,68,72,76,80,92] {
                    line += String(format: " %d:%.3f", off, readFloat(d, off))
                }
                s += line + "\n"
            }
        }
        fputs(s, stderr)
        if let fp = GestureController.debugFP { fputs(s, fp); fflush(fp) }
    }

    // Locate the (x, y) float pair inside the touch struct.
    // The Magic Mouse (and built-in trackpad) expose the normalized touch POSITION
    // as a float pair in roughly [0,1]. We require the chosen pair to stay inside a
    // plausible normalized range AND show real movement — this rejects the many other
    // float fields (velocities, timestamps, kernel handles) whose magnitudes are huge
    // (tens, thousands) and would otherwise dominate a plain "largest area" scan.
    private func extractPoints(_ raw: [Data]) -> [(Float, Float)]? {
        let len = raw.first?.count ?? 0
        guard len >= 40 else { return nil }

        // (32,36) is the confirmed normalized-position offset for this device; try it
        // first, then (20,24) as a secondary guess. Using them in priority order (rather
        // than by bounding-box area) avoids falling back to coarse/quantized fields.
        for c in [(32, 36), (20, 24)] {
            if let p = bestPair(raw, a: c.0, b: c.1, requireRange: true) {
                if let pts = buildPoints(raw, ox: c.0, oy: c.1) {
                    if config.debug {
                        let line = String(format: "extract off=(%d,%d) w=%.3f h=%.3f\n", c.0, c.1, p.w, p.h)
                        fputs(line, stderr)
                        if let fp = GestureController.debugFP { fputs(line, fp); fflush(fp) }
                    }
                    return pts
                }
            }
        }
        // Fallback: scan every 4-byte pair, constrained to the normalized range.
        var best: (ox: Int, oy: Int, w: Float, h: Float)? = nil
        for a in stride(from: 0, through: len - 8, by: 4) {
            for b in stride(from: a + 4, through: len - 4, by: 4) {
                guard let p = bestPair(raw, a: a, b: b, requireRange: true) else { continue }
                let area = p.w * p.h
                if best == nil || area > (best!.w * best!.h) { best = (a, b, p.w, p.h) }
            }
        }
        guard let bst = best else { return nil }
        guard let pts = buildPoints(raw, ox: bst.ox, oy: bst.oy) else { return nil }
        if config.debug {
            let line = String(format: "extract FALLBACK off=(%d,%d) w=%.3f h=%.3f\n", bst.ox, bst.oy, bst.w, bst.h)
            fputs(line, stderr)
            if let fp = GestureController.debugFP { fputs(line, fp); fflush(fp) }
        }
        return pts
    }

    // Evaluate a single offset pair (or list) for a coherent normalized trajectory.
    // Returns nil if any value is non-finite, huge, outside [−0.5, 1.5] (when
    // requireRange is set), or the bounding box is degenerate.
    private func bestPair(_ raw: [Data], a: Int, b: Int, requireRange: Bool) -> (ox: Int, oy: Int, w: Float, h: Float)? {
        guard raw.allSatisfy({ $0.count > max(a, b) + 4 }) else { return nil }
        var xs: [Float] = [], ys: [Float] = []
        for d in raw {
            let x = readFloat(d, a), y = readFloat(d, b)
            if !x.isFinite || !y.isFinite || abs(x) > 1e6 || abs(y) > 1e6 { return nil }
            xs.append(x); ys.append(y)
        }
        let w = xs.max()! - xs.min()!, h = ys.max()! - ys.min()!
        // Require real movement in at least one axis (a swipe can be thin in the other).
        guard max(w, h) > 0.12 else { return nil }
        if requireRange {
            let lo = min(xs.min()!, ys.min()!), hi = max(xs.max()!, ys.max()!)
            guard lo >= -0.5, hi <= 1.5 else { return nil }
        }
        return (a, b, w, h)
    }

    private func bestPair(_ raw: [Data], offsets: [(ox: Int, oy: Int)], requireRange: Bool) -> (ox: Int, oy: Int, w: Float, h: Float)? {
        var best: (ox: Int, oy: Int, w: Float, h: Float)? = nil
        for c in offsets {
            guard let p = bestPair(raw, a: c.ox, b: c.oy, requireRange: requireRange) else { continue }
            if best == nil || (p.w * p.h) > (best!.w * best!.h) { best = p }
        }
        return best
    }

    private func buildPoints(_ raw: [Data], ox: Int, oy: Int) -> [(Float, Float)]? {
        guard raw.allSatisfy({ $0.count > max(ox, oy) + 4 }) else { return nil }
        return raw.map { (readFloat($0, ox), readFloat($0, oy)) }
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

        // Decide the gesture, then log the metrics + result to both stderr and the
        // debug file so the detection can be verified offline.
        var result: String? = nil

        // Tap: short, tiny movement.
        if duration < 0.35, w < 0.18, h < 0.18 { result = "tap" }
        // Circle: most of the loop traced, roughly constant radius, and the path
        // returns close to where it started *relative to its total length*. Using
        // `straight` (= netDist / path) instead of an end-near-start distance means a
        // single loop OR several loops drawn in one continuous stroke both classify
        // as a circle (the start/end are far apart in a multi-loop stroke, but the
        // net displacement is tiny compared with the long path).
        else if meanR > 0.1, std / meanR < Float(config.maxRadiusStd),
                sweep > Float(config.minAngularCoverage), straight < Float(config.maxClosure) { result = "circle" }
        // Swipe: a fairly straight drag with significant net movement.
        else if netDist > 0.12, straight > 0.75 {
            if abs(netDx) > abs(netDy) { result = netDx > 0 ? "swipeRight" : "swipeLeft" }
            else { result = netDy > 0 ? "swipeDown" : "swipeUp" }
        }

        if config.debug {
            let cls = String(format: "classify dur=%.2f w=%.2f h=%.2f sweep=%.2f std=%.2f dlast=%.2f net=%.2f straight=%.2f => %@\n",
                             duration, w, h, sweep, std / meanR, dlast, netDist, straight, result ?? "nil")
            fputs(cls, stderr)
            if let fp = GestureController.debugFP { fputs(cls, fp); fflush(fp) }
        }
        return result
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
        let fired = String(format: "FIRED gesture=%@ keyCode=%u flag=%@\n", name, keyCode, b.flag)
        fputs(fired, stderr)
        if let fp = GestureController.debugFP { fputs(fired, fp); fflush(fp) }
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
