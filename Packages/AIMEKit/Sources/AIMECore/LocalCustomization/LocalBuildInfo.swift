import Foundation

/// Identity of the local build this process belongs to (local customization).
///
/// Read once from the enclosing app's Info.plist. `project.local.yml` adds
/// `AIMELocalCustomization`; the preview staging rewrites every bundle id to
/// `….voicepreview…`. Without either, every value is the upstream default, so
/// upstream builds and tests behave exactly as upstream.
public enum LocalBuildInfo {
    struct Identity: Equatable {
        var isPreview = false
        var customizesVocabulary = false
    }

    static let current = identity(from: enclosingAppInfo())

    /// Independent input-method processes cannot share LevelDB user dictionaries, so
    /// the preview keeps its own workspace next to a production AIME.
    public static var dataFolderName: String { current.isPreview ? "AIME Voice Preview" : "AIME" }

    public static var inputMethodBundleID: String {
        current.isPreview ? "app.zool.inputmethod.aime.voicepreview" : "app.zool.inputmethod.aime"
    }

    public static var inputModeID: String { inputMethodBundleID + ".hans" }

    /// Whether subscription tables are mounted as learnable dictionaries
    /// (see `LocalVocabularyCustomization`).
    public static var customizesVocabulary: Bool { current.customizesVocabulary }

    static func identity(from info: [String: Any]?) -> Identity {
        Identity(
            isPreview: (info?["CFBundleIdentifier"] as? String)?.contains(".voicepreview") == true,
            customizesVocabulary: info?["AIMELocalCustomization"] as? Bool == true
        )
    }

    /// Console helpers (`Contents/Helpers/aime`) and launchd input methods may not expose
    /// the wrapper through `Bundle.main`; read the enclosing application's public metadata.
    private static func enclosingAppInfo() -> [String: Any]? {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let application = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let infoURL = application.appendingPathComponent("Contents/Info.plist")
        let info = (try? Data(contentsOf: infoURL)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        }
        return info ?? Bundle.main.infoDictionary
    }
}
