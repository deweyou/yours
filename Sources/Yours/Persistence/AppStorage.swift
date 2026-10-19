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
                return try resolve(
                    isDebug: true, environment: ProcessInfo.processInfo.environment, arguments: ProcessInfo.processInfo.arguments)
            #elseif SWIFT_PACKAGE
                return try resolve(isDebug: true, environment: [:])
            #else
                return try resolve(isDebug: false, environment: [:])
            #endif
        } catch {
            preconditionFailure("Invalid UI-test session. Refusing to open another library.")
        }
    }()

    static func resolve(isDebug: Bool, environment: [String: String], arguments: [String] = [], root: URL = .applicationSupportDirectory)
        throws -> AppStorage
    {
        var value = isDebug ? environment["YOURS_UI_TEST_SESSION"] : nil
        if isDebug, let index = arguments.firstIndex(of: "-YoursUITestSession") {
            guard arguments.indices.contains(index + 1) else { throw ConfigurationError.invalidTestSession }
            let argument = arguments[index + 1]
            guard value == nil || value == argument else { throw ConfigurationError.invalidTestSession }
            value = argument
        }
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
}
