/// File logging for mx (`--log-file <path>`).
///
/// Redirects swift-log output (HTTP transport, sync, Olm) from the console
/// to a file. Formatting and level filtering stay with swift-log's
/// `StreamLogHandler`; this file only provides the append-only sink.
///
/// The file is created with owner-only (0600) permissions since debug logs
/// can contain key material. REPL interaction itself stays on the console.
import Foundation
import Logging

/// Append-only text sink writing to a log file. A class so every logger
/// created by the bootstrap closure shares one handle; writes are
/// serialized with a lock. Matches swift-log's own `StdioOutputStream`.
final class FileOutputStream: TextOutputStream, @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(path: String) throws {
        let expanded = (path as NSString).expandingTildeInPath
        FileManager.default.createFile(
            atPath: expanded, contents: nil,
            attributes: [.posixPermissions: 0o600])
        handle = try FileHandle(forWritingTo: URL(fileURLWithPath: expanded))
        try handle.seekToEnd()
    }

    func write(_ string: String) {
        lock.lock()
        defer { lock.unlock() }
        if let data = string.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }
}

enum FileLogging {
    /// Process-lifetime holder so the stream outlives every logger.
    /// Written once in `main` before any task starts.
    nonisolated(unsafe) private static var stream: FileOutputStream?

    /// Open the file and redirect all swift-log output to it. Throws when
    /// the file can't be opened, leaving console logging untouched.
    static func enable(path: String) throws {
        let opened = try FileOutputStream(path: path)
        stream = opened
        LoggingSystem.bootstrap { label in
            StreamLogHandler(label: label, stream: opened)
        }
    }
}
