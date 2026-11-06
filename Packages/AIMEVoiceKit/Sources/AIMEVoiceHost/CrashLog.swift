public import Foundation

/// Formatting and discovery for crash records. Deliberately pure so the format
/// is testable without crashing anything.

/// A record kind: the uncaught exception path or a signal path.
public enum CrashLogKind: Equatable {
    case exception
    case signal(Int32)
}

public enum CrashLog {

    public static let filePrefix = "crash-"
    public static let fileExtension = "log"

    /// Human-readable record. Everything missing degrades gracefully — a crash
    /// report that throws while being written is worse than a sparse one.
    public static func report(
        kind: CrashLogKind,
        name: String?,
        reason: String?,
        stack: [String]
    ) -> String {
        var lines: [String] = []
        lines.append("AIME crash report")
        lines.append("time: \(timestamp())")

        switch kind {
        case .exception:
            lines.append("kind: exception")
        case .signal(let number):
            lines.append("kind: signal(\(number)) \(signalName(number))")
        }

        if let name, !name.isEmpty { lines.append("name: \(name)") }
        if let reason, !reason.isEmpty { lines.append("reason: \(reason)") }
        lines.append("version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")

        if !stack.isEmpty {
            lines.append("trace:")
            lines.append(contentsOf: stack)
        }
        return lines.joined(separator: "\n")
    }

    /// Crash files in `directory`, newest first. Missing directory is not an
    /// error — the app may never have crashed.
    public static func existingReports(in directory: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .filter {
                $0.lastPathComponent.hasPrefix(filePrefix)
                    && $0.pathExtension == fileExtension
            }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return l > r
            }
    }

    /// Where crash records live.
    public static var directory: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library")
        return base.appendingPathComponent("Logs/AIME")
    }

    public static func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    public static func newReportURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(filePrefix)\(formatter.string(from: Date()))-\(getpid()).\(fileExtension)"
        return directory.appendingPathComponent(name)
    }

    /// Header written when the app starts. If the process dies, the rest of the
    /// file (appended by the signal handler) follows it.
    public static func sessionHeader() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return [
            "AIME session (running until this line is followed by a termination note)",
            "time: \(timestamp())",
            "version: \(version)",
            "pid: \(getpid())",
        ].joined(separator: "\n") + "\n"
    }

    public static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSZ"
        return formatter.string(from: Date())
    }

    private static func signalName(_ number: Int32) -> String {
        switch number {
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGILL: return "SIGILL"
        case SIGFPE: return "SIGFPE"
        case SIGTRAP: return "SIGTRAP"
        default: return "SIG\(number)"
        }
    }
}
