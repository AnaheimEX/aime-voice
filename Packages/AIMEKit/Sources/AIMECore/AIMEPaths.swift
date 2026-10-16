public import Foundation

/// Well-known locations. Everything AIME writes lives under `userDataDir`; the
/// Squirrel directory is only ever read.
public struct AIMEPaths: Sendable, Equatable {
    public var userDataDir: URL
    public var logDir: URL
    /// Read-only shipped data (AIME.app/Contents/SharedSupport). Needed to compose the
    /// `aime/defaults` layer; nil in contexts that only touch user layers.
    public var sharedDataDir: URL?

    public init(userDataDir: URL, logDir: URL? = nil, sharedDataDir: URL? = nil) {
        self.userDataDir = userDataDir
        self.logDir = logDir ?? userDataDir.appendingPathComponent("logs", isDirectory: true)
        self.sharedDataDir = sharedDataDir
    }

    /// `~/Library/AIME/Rime`, overridable with `AIME_USER_DIR` for tests and scripting.
    public static var standard: AIMEPaths {
        let env = ProcessInfo.processInfo.environment
        if let override = env["AIME_USER_DIR"], !override.isEmpty {
            return AIMEPaths(userDataDir: URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true))
        }
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        // Independent input-method processes cannot share LevelDB user dictionaries.
        // Preview and its settings use one workspace; the production workspace stays separate.
        // Console helpers and launchd input methods may not expose the wrapper ID
        // through Bundle.main; read the enclosing application's public metadata.
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let application = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let infoURL = application.appendingPathComponent("Contents/Info.plist")
        let info = (try? Data(contentsOf: infoURL)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        }
        let identifier = info?["CFBundleIdentifier"] as? String ?? Bundle.main.bundleIdentifier
        let preview = identifier?.contains(".voicepreview") == true
        let name = preview ? "AIME Voice Preview" : "AIME"
        return AIMEPaths(
            userDataDir: library.appendingPathComponent("\(name)/Rime", isDirectory: true),
            logDir: library.appendingPathComponent("Logs/\(name)", isDirectory: true)
        )
    }

    /// The Squirrel (鼠须管) user directory, used as an import source only.
    public static var squirrelUserDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Rime", isDirectory: true)
    }

    public var stagingDir: URL { userDataDir.appendingPathComponent("build", isDirectory: true) }
    public var aimeDir: URL { userDataDir.appendingPathComponent("aime", isDirectory: true) }
    public var importedDir: URL { aimeDir.appendingPathComponent("imported", isDirectory: true) }
    public var generatedDir: URL { aimeDir.appendingPathComponent("generated", isDirectory: true) }
    public var packagesDir: URL { aimeDir.appendingPathComponent("packages", isDirectory: true) }
    public var cacheDir: URL { aimeDir.appendingPathComponent("cache", isDirectory: true) }
    public var customPhraseFile: URL { userDataDir.appendingPathComponent("custom_phrase.txt") }

    public func builtConfig(_ configID: String) -> URL {
        stagingDir.appendingPathComponent("\(configID).yaml")
    }
}

/// Rime's own file-name convention for the configs AIME manages.
public enum ConfigTarget: Sendable, Hashable, CustomStringConvertible {
    /// `default.yaml`
    case `default`
    /// `<id>.schema.yaml`
    case schema(String)
    /// `aime.yaml` — the frontend config; same keys as Squirrel's `squirrel.yaml`.
    case frontend

    /// Config id as used by `config_open` / the `build/` directory.
    public var configID: String {
        switch self {
        case .default: "default"
        case let .schema(id): "\(id).schema"
        case .frontend: "aime"
        }
    }

    /// Base name of the `*.custom.yaml` patch file Rime auto-applies.
    public var customName: String {
        switch self {
        case .default: "default"
        case let .schema(id): id
        case .frontend: "aime"
        }
    }

    public var description: String { configID }

    public init?(file: String, schemaID: String?) {
        switch file {
        case "default": self = .default
        case "frontend", "aime", "squirrel": self = .frontend
        case "schema":
            guard let schemaID else { return nil }
            self = .schema(schemaID)
        default: return nil
        }
    }
}
