import Foundation
import DavKit
import MTPKit

/// Serves an MTP device as a DavBackend tree: storages are top-level folders,
/// objects beneath them. Owns the USB session (actor isolation = MTP's
/// one-command rule) and a path/handle cache so browsing doesn't re-walk the
/// device.
actor MTPDavBackend: DavBackend {

    private let urlHost: String
    private var device: MTPDevice?
    private(set) var deviceName = "MTP Device"

    private struct Node {
        var handle: UInt32
        var storageID: UInt32
        var isDirectory: Bool
        var size: UInt64
        var modified: Date?
        var created: Date?
    }

    private var storagesByName = [String: MTPStorageInfo]()
    /// Single-storage devices (Kindles, most phones without SD cards) skip the
    /// storage folder level entirely: the storage IS the volume root. Multi-
    /// storage devices keep one folder per storage.
    private var soleStorageName: String?
    private enum Container: Hashable {
        case storageRoot(UInt32)
        case folder(UInt32)
    }
    /// Loaded directory listings: container -> child name -> node.
    private var childrenCache = [Container: [String: Node]]()
    /// Finder junk (.DS_Store, ._AppleDouble) swallowed into RAM, keyed by
    /// joined path; never sent to the device.
    private var shadow = [String: Data]()
    private static let shadowFileCap = 1 << 20
    private static let shadowTotalCap = 64 << 20

    init(urlHost: String) {
        self.urlHost = urlHost
    }

    // MARK: - Device session

    private func connectedDevice() async throws -> MTPDevice {
        if let device { return device }
        guard let service = MTPDeviceLocator.findInterfaceService(urlHost: urlHost) else {
            throw DavError.unavailable
        }
        do {
            let transport = try USBTransport(interfaceService: service)
            let dev = MTPDevice(transport: transport)
            let info = try await dev.connect()
            if !info.model.isEmpty { deviceName = info.model }
            var names = [String: MTPStorageInfo]()
            for id in try await dev.storageIDs() {
                let storage = try await dev.storageInfo(id)
                var name = storage.description
                var n = 2
                while names[name] != nil {
                    name = "\(storage.description) \(n)"
                    n += 1
                }
                names[name] = storage
            }
            storagesByName = names
            soleStorageName = names.count == 1 ? names.keys.first : nil
            device = dev
            return dev
        } catch let error as MTPError {
            throw mapError(error)
        }
    }

    /// Connects eagerly so the app can surface busy/locked errors at attach
    /// time and name the volume; returns the device's model name.
    func prepare() async throws -> String {
        _ = try await connectedDevice()
        return deviceName
    }

    func shutdown() async {
        await device?.disconnect()
        device = nil
        childrenCache.removeAll()
    }

    private func mapError(_ error: MTPError) -> DavError {
        DebugLog.log("mtp error: \(error)")
        switch error.kind {
        case .deviceGone, .deviceBusy: return .unavailable
        case .response(let code) where code == .storeFull: return .insufficientStorage
        case .response(let code) where code == .accessDenied || code == .objectWriteProtected || code == .storeReadOnly:
            return .forbidden
        case .response(let code) where code == .invalidObjectHandle || code == .invalidParentObject:
            return .notFound
        default: return .forbidden
        }
    }

    // MARK: - Tree resolution

    private func isJunkName(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._") || name == ".Trashes"
            || name == ".Spotlight-V100" || name == ".fseventsd"
            || name == ".TemporaryItems" || name == ".metadata_never_index"
    }

    private func children(of container: Container) async throws -> [String: Node] {
        if let cached = childrenCache[container] { return cached }
        let device = try await connectedDevice()
        let storageID: UInt32
        let parentHandle: UInt32
        switch container {
        case .storageRoot(let id):
            storageID = id
            parentHandle = PTP.rootParentHandle
        case .folder(let handle):
            // Find the folder's storage from any cached node; fall back to
            // asking the device.
            let info = try await device.objectInfo(handle)
            storageID = info.storageID
            parentHandle = handle
        }
        let handles = try await device.objectHandles(storageID: storageID, parentHandle: parentHandle)
        var out = [String: Node]()
        for handle in handles {
            guard let info = try? await device.objectInfo(handle) else { continue }
            var size = UInt64(info.compressedSize)
            if info.sizeNeedsPropQuery, !info.isFolder {
                size = (try? await device.objectSize64(handle)) ?? size
            }
            var name = info.filename.isEmpty ? "object-\(handle)" : info.filename
            while out[name] != nil { name = "_" + name }
            out[name] = Node(
                handle: handle, storageID: info.storageID, isDirectory: info.isFolder,
                size: size, modified: info.dateModified, created: info.dateCreated
            )
        }
        childrenCache[container] = out
        return out
    }

    private enum Resolved {
        case root
        case storage(String, MTPStorageInfo)
        case node(Node)
    }

    private func resolve(_ path: [String]) async throws -> Resolved {
        if path.isEmpty { return .root }
        _ = try await connectedDevice()
        guard let storage = storagesByName[path[0]] else { throw DavError.notFound }
        if path.count == 1 { return .storage(path[0], storage) }

        var container = Container.storageRoot(storage.storageID)
        var node: Node?
        for segment in path.dropFirst() {
            let siblings = try await children(of: container)
            guard let found = siblings[segment] else { throw DavError.notFound }
            node = found
            container = .folder(found.handle)
        }
        return .node(node!)
    }

    /// Parent container + final name for a path (for create/delete/move).
    private func resolveParent(_ path: [String]) async throws -> (Container, String) {
        guard let name = path.last else { throw DavError.forbidden }
        let parentPath = Array(path.dropLast())
        switch try await resolve(parentPath) {
        case .root:
            throw DavError.forbidden // nothing real lives beside the storages
        case .storage(_, let info):
            return (.storageRoot(info.storageID), name)
        case .node(let node):
            guard node.isDirectory else { throw DavError.conflict }
            return (.folder(node.handle), name)
        }
    }

    private func storageID(of container: Container) -> UInt32? {
        switch container {
        case .storageRoot(let id): return id
        case .folder(let handle):
            for nodes in childrenCache.values {
                for node in nodes.values where node.handle == handle {
                    return node.storageID
                }
            }
            return nil
        }
    }

    private func parentHandle(of container: Container) -> UInt32 {
        switch container {
        case .storageRoot: return PTP.rootParentHandle
        case .folder(let handle): return handle
        }
    }

    private func shadowKey(_ path: [String]) -> String {
        path.joined(separator: "/")
    }

    /// Maps a client-visible path to the internal storage-prefixed path.
    private func internalPath(_ path: [String]) async throws -> [String] {
        _ = try await connectedDevice()
        if let sole = soleStorageName {
            return [sole] + path
        }
        return path
    }

    // MARK: - DavBackend

    func stat(path clientPath: [String]) async throws -> DavEntry {
        _ = try await connectedDevice()
        // The flattened root is the device itself.
        if clientPath.isEmpty, soleStorageName != nil {
            return DavEntry(name: deviceName, isDirectory: true, size: 0)
        }
        let path = try await internalPath(clientPath)
        return try await statInternal(path: path)
    }

    private func statInternal(path: [String]) async throws -> DavEntry {
        if let name = path.last {
            if let data = shadow[shadowKey(path)] {
                return DavEntry(name: name, isDirectory: false, size: UInt64(data.count), modified: Date())
            }
            if isJunkName(name) { throw DavError.notFound }
        }
        switch try await resolve(path) {
        case .root:
            return DavEntry(name: deviceName, isDirectory: true, size: 0)
        case .storage(let name, _):
            return DavEntry(name: name, isDirectory: true, size: 0)
        case .node(let node):
            return DavEntry(
                name: path.last ?? "", isDirectory: node.isDirectory,
                size: node.size, modified: node.modified, created: node.created
            )
        }
    }

    func list(path clientPath: [String]) async throws -> [DavEntry] {
        let path = try await internalPath(clientPath)
        switch try await resolve(path) {
        case .root:
            return storagesByName.keys.sorted().map {
                DavEntry(name: $0, isDirectory: true, size: 0)
            }
        case .storage(_, let info):
            let nodes = try await children(of: .storageRoot(info.storageID))
            return entries(from: nodes)
        case .node(let node):
            guard node.isDirectory else { throw DavError.notFound }
            let nodes = try await children(of: .folder(node.handle))
            return entries(from: nodes)
        }
    }

    private func entries(from nodes: [String: Node]) -> [DavEntry] {
        nodes.map { name, node in
            DavEntry(name: name, isDirectory: node.isDirectory, size: node.size, modified: node.modified, created: node.created)
        }.sorted { $0.name < $1.name }
    }

    func read(path clientPath: [String], offset: UInt64, length: Int) async throws -> Data {
        let path = try await internalPath(clientPath)
        if let data = shadow[shadowKey(path)] {
            guard offset < UInt64(data.count) else { return Data() }
            let start = Int(offset)
            return data.subdata(in: start..<min(start + length, data.count))
        }
        guard case .node(let node) = try await resolve(path), !node.isDirectory else {
            throw DavError.notFound
        }
        guard offset < node.size else { return Data() }
        let device = try await connectedDevice()
        do {
            let want = Int(min(UInt64(length), node.size - offset))
            return try await device.readObject(handle: node.handle, offset: offset, length: want)
        } catch let error as MTPError {
            throw mapError(error)
        }
    }

    func write(path clientPath: [String], contentsOf url: URL) async throws {
        let path = try await internalPath(clientPath)
        guard let name = path.last else { throw DavError.forbidden }

        // Junk never reaches the device.
        if isJunkName(name) {
            let data = (try? Data(contentsOf: url)) ?? Data()
            guard data.count <= Self.shadowFileCap,
                  shadow.values.reduce(0, { $0 + $1.count }) + data.count <= Self.shadowTotalCap else {
                throw DavError.insufficientStorage
            }
            shadow[shadowKey(path)] = data
            return
        }

        let (container, filename) = try await resolveParent(path)
        guard let storageID = storageID(of: container) else { throw DavError.conflict }
        let device = try await connectedDevice()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0

        do {
            // MTP has no overwrite: replace = delete old object + send new.
            if let existing = try await children(of: container)[filename] {
                guard !existing.isDirectory else { throw DavError.exists }
                try await device.deleteObject(existing.handle)
            }
            let handle = try await device.sendObject(
                storageID: storageID, parentHandle: parentHandle(of: container),
                name: filename, fileURL: url, size: size, modified: Date()
            )
            childrenCache[container]?[filename] = Node(
                handle: handle, storageID: storageID, isDirectory: false,
                size: size, modified: Date(), created: Date()
            )
        } catch let error as MTPError {
            throw mapError(error)
        }
    }

    func delete(path clientPath: [String]) async throws {
        let path = try await internalPath(clientPath)
        if shadow.removeValue(forKey: shadowKey(path)) != nil { return }
        let (container, name) = try await resolveParent(path)
        guard let node = try await children(of: container)[name] else { throw DavError.notFound }
        let device = try await connectedDevice()
        do {
            try await device.deleteObject(node.handle)
        } catch let error as MTPError {
            throw mapError(error)
        }
        childrenCache[container]?.removeValue(forKey: name)
        if node.isDirectory {
            childrenCache.removeValue(forKey: .folder(node.handle))
        }
    }

    func makeDirectory(path clientPath: [String]) async throws {
        let path = try await internalPath(clientPath)
        let (container, name) = try await resolveParent(path)
        guard let storageID = storageID(of: container) else { throw DavError.conflict }
        guard try await children(of: container)[name] == nil else { throw DavError.exists }
        let device = try await connectedDevice()
        do {
            let handle = try await device.createFolder(
                storageID: storageID, parentHandle: parentHandle(of: container), name: name
            )
            childrenCache[container]?[name] = Node(
                handle: handle, storageID: storageID, isDirectory: true,
                size: 0, modified: Date(), created: Date()
            )
            childrenCache[.folder(handle)] = [:]
        } catch let error as MTPError {
            throw mapError(error)
        }
    }

    func move(from clientFrom: [String], to clientTo: [String]) async throws {
        let from = try await internalPath(clientFrom)
        let to = try await internalPath(clientTo)
        // Shadow entries just move in RAM.
        if let data = shadow.removeValue(forKey: shadowKey(from)) {
            shadow[shadowKey(to)] = data
            return
        }
        let (fromContainer, fromName) = try await resolveParent(from)
        let (toContainer, toName) = try await resolveParent(to)
        guard let node = try await children(of: fromContainer)[fromName] else { throw DavError.notFound }
        guard let toStorage = storageID(of: toContainer), toStorage == node.storageID else {
            // Cross-storage moves would need copy+delete; the kernel client
            // falls back to that itself when MOVE fails.
            throw DavError.forbidden
        }
        let device = try await connectedDevice()
        do {
            if fromContainer != toContainer {
                try await device.moveObject(node.handle, toStorage: toStorage, parentHandle: parentHandle(of: toContainer))
            }
            if fromName != toName {
                try await device.renameObject(node.handle, to: toName)
            }
        } catch let error as MTPError {
            throw mapError(error)
        }
        childrenCache[fromContainer]?.removeValue(forKey: fromName)
        var moved = node
        moved.modified = Date()
        childrenCache[toContainer]?[toName] = moved
    }

    func quota() async throws -> (total: UInt64, free: UInt64) {
        _ = try await connectedDevice()
        var total: UInt64 = 0
        var free: UInt64 = 0
        for storage in storagesByName.values {
            total += storage.maxCapacity
            free += storage.freeSpace
        }
        return (total, free)
    }
}
