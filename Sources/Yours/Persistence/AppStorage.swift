import Foundation

/// Build identity, local documents, preferences, and CloudKit must use the same boundary.
struct AppStorage: Equatable, Sendable {
    enum ConfigurationError: Error {
        case invalidTestSession
    }
    enum Profile: Equatable, Sendable {
        case production, development
        case test(UUID)
    }

    let profile: Profile
    let root: URL

    static let current: AppStorage = {
        do {
            #if DEBUG
                var environment = ProcessInfo.processInfo.environment
                #if os(macOS) && !SWIFT_PACKAGE
                    if environment["YOURS_UI_TEST_SESSION"] == nil,
                        let session = try consumeTestRelaunch(root: .applicationSupportDirectory, bundleURL: Bundle.main.bundleURL)
                    {
                        environment["YOURS_UI_TEST_SESSION"] = session.uuidString
                    }
                #endif
                return try resolve(isDebug: true, environment: environment)
            #elseif SWIFT_PACKAGE
                return try resolve(isDebug: true, environment: [:])
            #else
                return try resolve(isDebug: false, environment: [:])
            #endif
        } catch {
            preconditionFailure("Invalid UI-test session. Refusing to open another library.")
        }
    }()

    static func resolve(isDebug: Bool, environment: [String: String], root: URL = .applicationSupportDirectory)
        throws -> AppStorage
    {
        let value = isDebug ? environment["YOURS_UI_TEST_SESSION"] : nil
        if let value {
            guard let session = UUID(uuidString: value) else { throw ConfigurationError.invalidTestSession }
            return AppStorage(profile: .test(session), root: root)
        }
        return AppStorage(profile: isDebug ? .development : .production, root: root)
    }

    var directory: URL {
        switch profile {
        case .production: root.appendingPathComponent("Yours", isDirectory: true)
        case .development: root.appendingPathComponent("YoursDevelopment", isDirectory: true)
        case .test(let id): root.appendingPathComponent("YoursUITests/\(id.uuidString)", isDirectory: true)
        }
    }

    var preferenceSuite: String? {
        switch profile {
        case .production: nil
        case .development: "YoursDevelopment.preferences"
        case .test(let id): "YoursUITests.\(id.uuidString).preferences"
        }
    }

    var allowsCloudSync: Bool {
        if case .test = profile { return false }
        return true
    }

    var cloudContainerSuffix: String {
        profile == .production ? "" : ".development"
    }

    private struct TestRelaunch: Codable {
        var session: UUID
        var bundleURL: URL
        var expiresAt: Date
    }

    private static func testRelaunchURL(root: URL) -> URL {
        root.appendingPathComponent("YoursUITests/language-relaunch.json")
    }

    /// LaunchServices may discard sandboxed launch arguments/environment.
    /// A short-lived, bundle-bound token carries only the isolated test UUID.
    func prepareTestRelaunch(bundleURL: URL, now: Date = .now) throws {
        guard case .test(let session) = profile else { return }
        let url = Self.testRelaunchURL(root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(TestRelaunch(session: session, bundleURL: bundleURL, expiresAt: now.addingTimeInterval(60)))
            .write(to: url, options: .atomic)
    }

    static func consumeTestRelaunch(root: URL, bundleURL: URL, now: Date = .now) throws -> UUID? {
        let url = testRelaunchURL(root: root)
        let data: Data
        do { data = try Data(contentsOf: url) } catch CocoaError.fileReadNoSuchFile { return nil }
        let token = try JSONDecoder().decode(TestRelaunch.self, from: data)
        guard token.bundleURL == bundleURL else { return nil }
        try FileManager.default.removeItem(at: url)
        guard token.expiresAt > now, token.expiresAt <= now.addingTimeInterval(60) else { return nil }
        return token.session
    }

    func cancelTestRelaunch(bundleURL: URL) throws {
        guard case .test = profile else { return }
        _ = try Self.consumeTestRelaunch(root: root, bundleURL: bundleURL)
    }
}
