import Foundation

/// Append-only debug log at ~/Library/Logs/Moorage.log. NSLog from this app
/// has proven unqueryable via `log show`; a plain file always works.
enum DebugLog {
    private static let handle: FileHandle? = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Moorage.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        _ = try? h?.seekToEnd()
        return h
    }()
    private static let lock = NSLock()
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.write(contentsOf: Data("\(stamp.string(from: Date())) \(line)\n".utf8))
    }
}
