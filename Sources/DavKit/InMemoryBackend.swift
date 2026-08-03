import Foundation

/// A RAM-backed DavBackend for tests and local mount verification: proves the
/// whole server + mount_webdav path with no device attached.
public actor InMemoryBackend: DavBackend {

    private final class Node {
        var isDirectory: Bool
        var data: Data
        var children: [String: Node]
        var modified: Date
        let created: Date

        init(isDirectory: Bool, data: Data = Data()) {
            self.isDirectory = isDirectory
            self.data = data
            self.children = [:]
            self.modified = Date()
            self.created = Date()
        }
    }

    private let root = Node(isDirectory: true)

    public init() {}

    /// Seed helper for tests: creates intermediate directories.
    public func seed(path: [String], data: Data?) {
        var node = root
        for (index, segment) in path.enumerated() {
            let isLast = index == path.count - 1
            if let existing = node.children[segment] {
                node = existing
            } else {
                let child = Node(isDirectory: isLast ? data == nil : true, data: (isLast ? data : nil) ?? Data())
                node.children[segment] = child
                node = child
            }
        }
    }

    private func node(at path: [String]) -> Node? {
        var node = root
        for segment in path {
            guard let child = node.children[segment] else { return nil }
            node = child
        }
        return node
    }

    private func entry(name: String, node: Node) -> DavEntry {
        DavEntry(
            name: name, isDirectory: node.isDirectory,
            size: UInt64(node.data.count),
            modified: node.modified, created: node.created
        )
    }

    public func stat(path: [String]) async throws -> DavEntry {
        guard let node = node(at: path) else { throw DavError.notFound }
        return entry(name: path.last ?? "root", node: node)
    }

    public func list(path: [String]) async throws -> [DavEntry] {
        guard let node = node(at: path), node.isDirectory else { throw DavError.notFound }
        return node.children.map { entry(name: $0.key, node: $0.value) }.sorted { $0.name < $1.name }
    }

    public func read(path: [String], offset: UInt64, length: Int) async throws -> Data {
        guard let node = node(at: path), !node.isDirectory else { throw DavError.notFound }
        guard offset < UInt64(node.data.count) else { return Data() }
        let start = Int(offset)
        let end = min(start + length, node.data.count)
        return node.data.subdata(in: start..<end)
    }

    public func write(path: [String], contentsOf url: URL) async throws {
        guard let name = path.last else { throw DavError.forbidden }
        guard let parent = node(at: Array(path.dropLast())), parent.isDirectory else {
            throw DavError.conflict
        }
        let data = (try? Data(contentsOf: url)) ?? Data()
        if let existing = parent.children[name] {
            guard !existing.isDirectory else { throw DavError.exists }
            existing.data = data
            existing.modified = Date()
        } else {
            parent.children[name] = Node(isDirectory: false, data: data)
        }
    }

    public func delete(path: [String]) async throws {
        guard let name = path.last,
              let parent = node(at: Array(path.dropLast())),
              parent.children[name] != nil else { throw DavError.notFound }
        parent.children.removeValue(forKey: name)
    }

    public func makeDirectory(path: [String]) async throws {
        guard let name = path.last else { throw DavError.forbidden }
        guard let parent = node(at: Array(path.dropLast())), parent.isDirectory else {
            throw DavError.conflict
        }
        guard parent.children[name] == nil else { throw DavError.exists }
        parent.children[name] = Node(isDirectory: true)
    }

    public func move(from: [String], to: [String]) async throws {
        guard let fromName = from.last, let toName = to.last,
              let fromParent = node(at: Array(from.dropLast())),
              let moving = fromParent.children[fromName],
              let toParent = node(at: Array(to.dropLast())), toParent.isDirectory else {
            throw DavError.notFound
        }
        fromParent.children.removeValue(forKey: fromName)
        toParent.children[toName] = moving
    }

    public func quota() async throws -> (total: UInt64, free: UInt64) {
        (total: 1 << 30, free: 1 << 29)
    }
}
