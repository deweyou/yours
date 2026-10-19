#if os(macOS)
    import AppKit

    @MainActor
    enum AppLanguageRestart {
        private static var pendingHelper: Process?

        static func cancel() {
            if let pendingHelper, pendingHelper.isRunning { pendingHelper.terminate() }
            pendingHelper = nil
            // Expiration also prevents stale tokens being reused if cleanup fails.
            try? AppStorage.current.cancelTestRelaunch(bundleURL: Bundle.main.bundleURL)
        }

        static func restart() throws {
            let app = Bundle.main.bundleURL
            guard app.pathExtension == "app" else { throw CocoaError(.executableNotLoadable) }
            // Saved preferences select the language. The one-shot token keeps
            // UI-test storage isolated when LaunchServices drops launch arguments.
            try AppStorage.current.prepareTestRelaunch(bundleURL: app)
            // Wait for the old process to exit before reopening this same app.
            // Arguments are passed separately, never interpolated into shell code.
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/sh")
            helper.arguments = [
                "-c",
                """
                attempts=0
                while /bin/kill -0 "$1" 2>/dev/null; do
                    [ "$attempts" -lt 300 ] || exit 1
                    /bin/sleep 0.1
                    attempts=$((attempts + 1))
                done
                exec /usr/bin/open "$2"
                """,
                "yours-language-restart", String(ProcessInfo.processInfo.processIdentifier), app.path,
            ]
            do { try helper.run() } catch {
                cancel()
                throw error
            }
            pendingHelper = helper
            NSApplication.shared.terminate(nil)
        }
    }
#endif
