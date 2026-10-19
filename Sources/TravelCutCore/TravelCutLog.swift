import Foundation

/// Debug output. Enabled by TRAVELCUT_DEBUG=1 (written to stderr, for the command line) or by the
/// app's "保存调试日志" switch (written to a file in the photo folder), so nobody has to launch the
/// app from Terminal to collect a log.
public final class TravelCutLog: @unchecked Sendable {
    private static let shared = TravelCutLog()
    private let lock = NSLock()
    private var file: FileHandle?
    private let toStderr = ProcessInfo.processInfo.environment["TRAVELCUT_DEBUG"] == "1"

    public static var isEnabled: Bool {
        shared.lock.lock(); defer { shared.lock.unlock() }
        return shared.toStderr || shared.file != nil
    }

    /// Starts writing to `url`, replacing an older log there.
    public static func start(at url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: url)
        shared.lock.lock(); shared.file = handle; shared.lock.unlock()
    }

    public static func stop() {
        shared.lock.lock(); defer { shared.lock.unlock() }
        try? shared.file?.close()
        shared.file = nil
    }

    public static func write(_ data: Data) {
        shared.lock.lock(); defer { shared.lock.unlock() }
        if shared.toStderr { FileHandle.standardError.write(data) }
        try? shared.file?.write(contentsOf: data)
    }
}
