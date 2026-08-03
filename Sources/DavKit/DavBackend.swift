import Foundation

/// One entry in the served tree.
public struct DavEntry: Sendable {
    public let name: String
    public let isDirectory: Bool
    public let size: UInt64
    public let modified: Date?
    public let created: Date?

    public init(name: String, isDirectory: Bool, size: UInt64, modified: Date? = nil, created: Date? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.created = created
    }
}

/// Errors a backend can surface; the server maps them to HTTP statuses.
public enum DavError: Error, Sendable {
    case notFound          // 404
    case exists            // 405 / 412
    case forbidden         // 403
    case conflict          // 409 (e.g. parent missing)
    case insufficientStorage // 507
    case unavailable       // 503 (device gone/busy)
}

/// The tree DavServer serves. Paths are arrays of decoded segments; [] is the
/// root. All methods are async; the server bridges from its blocking
/// connection threads.
public protocol DavBackend: Sendable {
    /// Metadata for the entry at path. Throws DavError.notFound if absent.
    func stat(path: [String]) async throws -> DavEntry
    /// Children of a directory.
    func list(path: [String]) async throws -> [DavEntry]
    /// Read a byte range of a file.
    func read(path: [String], offset: UInt64, length: Int) async throws -> Data
    /// Replace or create the file at path with the complete contents of a
    /// local temp file (WebDAV PUT is always whole-file, which matches MTP).
    func write(path: [String], contentsOf url: URL) async throws
    func delete(path: [String]) async throws
    func makeDirectory(path: [String]) async throws
    func move(from: [String], to: [String]) async throws
    /// Total/free bytes for quota reporting (Finder's capacity display).
    func quota() async throws -> (total: UInt64, free: UInt64)
}
