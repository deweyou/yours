#if os(macOS)
    import AppKit

    @MainActor
    enum AppLanguageRestart {
        private static var pendingHelper: Process?

        static func cancel() {
            if let pendingHelper, pendingHelper.isRunning { pendingHelper.terminate() }
            pendingHelper = nil
        }

        static func restart(language: AppPreferences.Language) throws {
            let app = Bundle.main.bundleURL
            guard app.pathExtension == "app" else { throw CocoaError(.executableNotLoadable) }
            // Wait for the old process to exit before reopening this same app.
            // Arguments are passed separately, never interpolated into shell code.
            // LaunchServices can retain the exited instance briefly and ignore
            // new arguments. Only after the PID exits, force a fresh launch so
            // the selected language and isolated test session reach main().
            // A cancelled termination leaves this helper to time out without
            // opening another instance or writing to the same library twice.
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/sh")
            let testSession: String
            if case .test(let session) = AppStorage.current.profile { testSession = session.uuidString } else { testSession = "" }
            helper.arguments = [
                "-c",
                """
                attempts=0
                while /bin/kill -0 "$1" 2>/dev/null; do
                    [ "$attempts" -lt 300 ] || exit 1
                    /bin/sleep 0.1
                    attempts=$((attempts + 1))
                done
                if [ -n "$4" ]; then
                    exec /usr/bin/open -n --env "YOURS_UI_TEST_SESSION=$4" "$2" --args -AppleLanguages "($3)" -ApplePersistenceIgnoreState YES -YoursLanguageRelaunch YES -YoursUITestSession "$4"
                else
                    exec /usr/bin/open -n "$2" --args -AppleLanguages "($3)" -ApplePersistenceIgnoreState YES -YoursLanguageRelaunch YES
                fi
                """,
                "yours-language-restart", String(ProcessInfo.processInfo.processIdentifier), app.path, language.rawValue,
                testSession,
            ]
            try helper.run()
            pendingHelper = helper
            NSApplication.shared.terminate(nil)
        }
    }
#endif
