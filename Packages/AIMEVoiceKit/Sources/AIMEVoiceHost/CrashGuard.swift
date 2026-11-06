import Darwin
import Foundation
import OSLog

/// Last line of defence: record what killed the app.
///
/// Two failure modes matter:
///  - **Objective-C exceptions** (`NSException`) — raised by `NSPasteboard`,
///    Accessibility and AppKit calls. Swift cannot catch them; uncaught, they
///    abort the process. `ObjCException.guardCall` prevents the ones we know
///    about; this handler catches everything else and leaves a note.
///  - **Signals** — `SIGABRT` from `fatalError`, `SIGSEGV` from bad memory
///    access. Nothing can recover from these, but the process can still write a
///    few bytes to a file descriptor it opened at startup.
///
/// Signal handlers may only use async-signal-safe calls (`write`, `open`,
/// `raise`). No allocation, no logging framework, no Swift string interpolation
/// inside the handler.
public enum CrashGuard {

    /// File descriptor held open for the lifetime of the process so the signal
    /// handler can write without opening anything.
    fileprivate nonisolated(unsafe) static var signalDescriptor: Int32 = -1

    /// Report file opened at startup. Signal handlers can only write, so the
    /// path has to exist beforehand. If the app exits normally the file is
    /// deleted; anything left behind means the process died abnormally.
    private(set) nonisolated(unsafe) static var activeReportURL: URL?

    /// Null-terminated path for the signal handler: `unlink` is async-signal-safe
    /// but building a Swift String is not, so the pointer is allocated once.
    fileprivate nonisolated(unsafe) static var activePathPointer: UnsafeMutablePointer<CChar>?

    private nonisolated(unsafe) static var installed = false

    /// Install handlers. Cheap and non-blocking, so it is safe to call from
    /// the process entry point.
    public static func install() {
        guard !installed else { return }
        installed = true

        CrashLog.ensureDirectory()
        reportPreviousCrash()

        // Objective-C exceptions: not signal context, so full API is available.
        // A top-level function is used because NSSetUncaughtExceptionHandler
        // needs a C function pointer, which cannot be a capturing closure.
        NSSetUncaughtExceptionHandler(vfHandleUncaughtException)

        // Signals: pre-create a timestamped report and keep it open, because a
        // handler may only `write` — it cannot build a path or a timestamp.
        let reportURL = CrashLog.newReportURL()
        activeReportURL = reportURL
        signalDescriptor = open(reportURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if signalDescriptor >= 0 {
            writeBytes(signalDescriptor, CrashLog.sessionHeader())
            fsync(signalDescriptor)
        }

        if let copied = strdup(reportURL.path) {
            activePathPointer = copied
        }

        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig, vfHandleSignal)
        }
        // SIGTERM means "quit now" (`pkill`, logout, Activity Monitor), not a
        // crash. Remove the pre-created report so it is not misreported later.
        signal(SIGTERM, vfHandleTerminate)
    }

    // MARK: - Signal path

    fileprivate static func handleSignal(_ sig: Int32) {
        // Async-signal-safe only.
        if signalDescriptor >= 0 {
            // Digits are formatted by hand: `sprintf` is not async-signal-safe.
            writeBytes(signalDescriptor, "terminated by signal ")
            writeDecimal(signalDescriptor, sig)
            writeBytes(signalDescriptor, "\n")
            fsync(signalDescriptor)
        }
        // Restore default behaviour and re-raise so the system still produces a
        // real crash report.
        signal(sig, SIG_DFL)
        raise(sig)
    }

    fileprivate static func writeBytes(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = Darwin.write(fd, base, buffer.count)
        }
    }

    /// Minimal integer → ASCII, because only async-signal-safe calls are allowed
    /// inside a signal handler.
    fileprivate static func writeDecimal(_ fd: Int32, _ value: Int32) {
        var digits = [UInt8](repeating: 0, count: 12)
        var number = value
        var negative = false
        if number < 0 {
            negative = true
            number = -number
        }
        var index = digits.count
        repeat {
            index -= 1
            digits[index] = UInt8(number % 10) + 48
            number /= 10
        } while number > 0
        if negative {
            index -= 1
            digits[index] = 45  // '-'
        }
        digits.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = Darwin.write(fd, base + index, buffer.count - index)
        }
    }

    // MARK: - Exception path

    fileprivate static func persist(_ report: String) {
        let url = CrashLog.newReportURL()
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // Nothing better to do here; the unified log still gets a line below.
        }
        os_log("uncaught exception recorded at %{public}@", log: logger, type: .error, url.lastPathComponent)
        logToUnified("AIME crashed: uncaught exception, see \(url.path)")
    }

    /// Remove the active report from signal context. Only `unlink` is used.
    fileprivate static func discardActiveReportFromSignal() {
        if signalDescriptor >= 0 {
            close(signalDescriptor)
            signalDescriptor = -1
        }
        if let path = activePathPointer {
            unlink(path)
        }
    }

    private static let logger = OSLog(subsystem: "app.zool.aime", category: "crash")

    /// Call from the app's terminate hook. A clean exit deletes the open
    /// report; a crash leaves it behind for the next launch to report.
    public static func markCleanExit() {
        if signalDescriptor >= 0 {
            close(signalDescriptor)
            signalDescriptor = -1
        }
        if let url = activeReportURL {
            try? FileManager.default.removeItem(at: url)
            activeReportURL = nil
        }
    }

    // MARK: - Previous run

    /// Surface a crash from a previous run into the unified log, so
    /// `log show` reveals it without hunting through files.
    private static func reportPreviousCrash() {
        let reports = CrashLog.existingReports(in: CrashLog.directory)
            .filter { $0 != activeReportURL }
        guard let latest = reports.first else { return }

        let summary = (try? String(contentsOf: latest, encoding: .utf8))?
            .split(separator: "\n")
            .prefix(6)
            .joined(separator: " | ") ?? "unreadable"

        os_log("previous crash report %{public}@: %{public}@", log: logger, type: .error, latest.lastPathComponent, summary)
        logToUnified("AIME previous crash: \(latest.path)")
    }

    private static func logToUnified(_ message: String) {
        os_log("%{public}@", log: logger, type: .error, message)
    }
}


// MARK: - C callbacks

/// Must be a free function: the API takes a C function pointer.
private func vfHandleUncaughtException(_ exception: NSException) {
    let report = CrashLog.report(
        kind: .exception,
        name: exception.name.rawValue,
        reason: exception.reason,
        stack: exception.callStackSymbols
    )
    CrashGuard.persist(report)
}

/// Async-signal-safe path: only `write`, `fsync`, `signal`, `raise`.
private func vfHandleSignal(_ sig: Int32) {
    CrashGuard.handleSignal(sig)
}


/// SIGTERM is a requested shutdown, not a crash.
private func vfHandleTerminate(_ sig: Int32) {
    CrashGuard.discardActiveReportFromSignal()
    signal(sig, SIG_DFL)
    raise(sig)
}
