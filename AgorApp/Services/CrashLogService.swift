import Foundation
import MetricKit

/// File-scope storage for the crash log directory — required because
/// `NSSetUncaughtExceptionHandler` takes a bare C function pointer that
/// cannot capture context (no closures allowed).
private var _crashLogDir: URL?

/// Called by the C-compatible uncaught-exception handler below.
private func _handleUncaughtException(_ exception: NSException) {
    guard let dir = _crashLogDir else { return }
    let ts = Int(Date().timeIntervalSince1970)
    let url = dir.appendingPathComponent("crash-exception-\(ts).txt")
    let text = """
    Uncaught Exception
    ==================
    Name:    \(exception.name.rawValue)
    Reason:  \(exception.reason ?? "(none)")
    Date:    \(Date())

    Call Stack
    ----------
    \(exception.callStackSymbols.joined(separator: "\n"))
    """
    try? text.data(using: .utf8)?.write(to: url)
}

/// Collects crash diagnostics from two sources:
///   1. MetricKit — `MXDiagnosticPayload` delivered by iOS on the next launch after a crash.
///   2. `NSSetUncaughtExceptionHandler` — catches ObjC exceptions before the process dies.
///
/// Crash files are written to `Caches/CrashLogs/` and survive until explicitly cleared.
/// The UI checks `CrashLogService.shared.hasCrashLog` to decide whether to show the button.
final class CrashLogService {
    static let shared = CrashLogService()

    private let crashLogsDir: URL
    private(set) var hasCrashLog: Bool = false

    // Separate NSObject subclass required because MXMetricManagerSubscriber is ObjC
    private var subscriber: MetricKitSubscriber?

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        crashLogsDir = caches.appendingPathComponent("CrashLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: crashLogsDir, withIntermediateDirectories: true)

        // Store dir in global so the C function pointer can reach it
        _crashLogDir = crashLogsDir
        NSSetUncaughtExceptionHandler(_handleUncaughtException)

        // MetricKit subscriber (delivers crash payloads on next launch after crash)
        let sub = MetricKitSubscriber(crashLogsDir: crashLogsDir) { [weak self] in
            DispatchQueue.main.async { self?.hasCrashLog = true }
        }
        MXMetricManager.shared.add(sub)
        subscriber = sub

        hasCrashLog = !listCrashLogURLs().isEmpty
    }

    // MARK: - Public API

    /// Returns the most recent crash log data and a suggested file name.
    func latestCrashLog() -> (data: Data, fileName: String)? {
        guard let url = listCrashLogURLs()
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .last
        else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (data, url.lastPathComponent)
    }

    func clearCrashLogs() {
        listCrashLogURLs().forEach { try? FileManager.default.removeItem(at: $0) }
        hasCrashLog = false
    }

    // MARK: - Internals

    private func listCrashLogURLs() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: crashLogsDir,
            includingPropertiesForKeys: nil
        ))?.filter { ["txt", "json"].contains($0.pathExtension) } ?? []
    }
}

// MARK: - MetricKit subscriber (must be NSObject)

private final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber {
    private let crashLogsDir: URL
    private let onNewCrashLog: () -> Void

    init(crashLogsDir: URL, onNewCrashLog: @escaping () -> Void) {
        self.crashLogsDir = crashLogsDir
        self.onNewCrashLog = onNewCrashLog
    }

    // Required — ignore metrics, we only care about diagnostics
    func didReceive(_ payloads: [MXMetricPayload]) {}

    // Optional — crash + hang + cpu + disk diagnostics
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let ts = Int(Date().timeIntervalSince1970)
            let url = crashLogsDir.appendingPathComponent("crash-metrickit-\(ts).json")
            try? payload.jsonRepresentation().write(to: url)
            onNewCrashLog()
        }
    }
}
