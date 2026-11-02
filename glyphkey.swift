// CLI entry point for GlyphKey (terminal / debugging use).
// The .app version lives in MouseGestureApp.swift.

import Foundation

@main
final class CLI {
    static func main() {
        let controller = GestureController.shared
        controller.onStatus = { s in fputs(s + "\n", stderr) }

        if CommandLine.arguments.contains("--selftest") {
            GestureController.runSelfTest()
            return
        }

        controller.start()
        fputs("GlyphKey is running. Draw a gesture on your Magic Mouse to trigger the key.\n", stderr)
        fputs("Press Ctrl+C to stop.\n", stderr)

        // Keep the process alive until Ctrl+C.
        let grp = DispatchGroup()
        grp.enter()
        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        src.setEventHandler { grp.leave() }
        src.resume()
        grp.wait()
        src.cancel()
        controller.stop()
        fputs("Stopped.\n", stderr)
    }
}
