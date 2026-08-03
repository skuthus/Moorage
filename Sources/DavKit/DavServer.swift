import Foundation

/// A WebDAV class-2 server bound to 127.0.0.1 on an ephemeral port, serving
/// one DavBackend. Built for exactly one client: macOS's webdavfs via
/// mount_webdav. Thread-per-connection with blocking I/O; the backend is
/// async and bridged per call. The URL namespace is prefixed with a random
/// token so other local processes can't guess the URL.
public final class DavServer: @unchecked Sendable {

    private let backend: any DavBackend
    /// Random path prefix; the mount URL is http://127.0.0.1:port/token/
    public let token: String
    public private(set) var port: UInt16 = 0
    private var listenFD: Int32 = -1
    private let stateLock = NSLock()
    private var running = false

    public var url: URL {
        URL(string: "http://127.0.0.1:\(port)/\(token)/")!
    }

    /// Per-request stderr logging, for development and the demo server.
    public var debugLogging = false

    public init(backend: any DavBackend) {
        self.backend = backend
        self.token = UUID().uuidString
    }

    private func logRequest(_ request: HTTPRequest) {
        guard debugLogging else { return }
        NSLog("dav: %@ %@ depth=%@ len=%d", request.method, request.rawTarget, request.header("depth") ?? "-", request.body.count)
    }

    public func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // ephemeral
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(fd, $0, &length)
            }
        }
        port = UInt16(bigEndian: bound.sin_port)
        listenFD = fd
        stateLock.lock(); running = true; stateLock.unlock()

        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.name = "DavServer accept"
        thread.start()
    }

    public func stop() {
        stateLock.lock()
        running = false
        stateLock.unlock()
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
    }

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private func acceptLoop() {
        while isRunning {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else {
                if isRunning { continue } else { break }
            }
            let thread = Thread { [weak self] in
                self?.serve(fd: clientFD)
            }
            thread.name = "DavServer connection"
            thread.start()
        }
    }

    // MARK: - Connection loop

    private func serve(fd: Int32) {
        let io = SocketIO(fd: fd)
        while isRunning {
            do {
                guard let request = try HTTPRequest.read(from: io) else { return }
                logRequest(request)
                try handle(request, io: io)
                if request.header("connection")?.lowercased() == "close" { return }
            } catch {
                if debugLogging { NSLog("dav: connection error %@", "\(error)") }
                return // connection torn down; SocketIO deinit closes fd
            }
        }
    }

    private final class ResultBox<V>: @unchecked Sendable {
        var result: Result<V, Error>?
    }

    /// Bridges the connection thread into the async backend.
    private func call<T: Sendable>(_ op: @escaping @Sendable () async throws -> T) throws -> T {
        let box = ResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = Result<T, Error>.success(try await op()) }
            catch { box.result = Result<T, Error>.failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.result!.get()
    }

    private func status(for error: Error) -> Int {
        switch error {
        case DavError.notFound: return 404
        case DavError.exists: return 405
        case DavError.forbidden: return 403
        case DavError.conflict: return 409
        case DavError.insufficientStorage: return 507
        case DavError.unavailable: return 503
        default: return 500
        }
    }

    // MARK: - Routing

    private func handle(_ request: HTTPRequest, io: SocketIO) throws {
        // OPTIONS * or any path: advertise class 2 so webdavfs mounts rw.
        if request.method == "OPTIONS" {
            try HTTPResponse.send(io, status: 200, headers: [
                ("Allow", "OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, PROPPATCH, MKCOL, MOVE, LOCK, UNLOCK"),
                ("DAV", "1, 2"),
                ("MS-Author-Via", "DAV"),
            ])
            return
        }

        // Everything else lives under /token/...
        var mutableSegments = request.pathSegments
        guard !mutableSegments.isEmpty, mutableSegments.first == token else {
            try HTTPResponse.send(io, status: 404)
            return
        }
        mutableSegments.removeFirst()
        let segments = mutableSegments

        do {
            switch request.method {
            case "PROPFIND": try propfind(request, path: segments, io: io)
            case "GET", "HEAD": try get(request, path: segments, io: io)
            case "PUT": try put(request, path: segments, io: io)
            case "DELETE":
                try call { [backend] in try await backend.delete(path: segments) }
                try HTTPResponse.send(io, status: 204)
            case "MKCOL":
                guard request.body.isEmpty else {
                    try HTTPResponse.send(io, status: 415)
                    return
                }
                try call { [backend] in try await backend.makeDirectory(path: segments) }
                try HTTPResponse.send(io, status: 201)
            case "MOVE": try move(request, from: segments, io: io)
            case "LOCK":
                let lockToken = "opaquelocktoken:\(UUID().uuidString)"
                try HTTPResponse.send(io, status: 200, headers: [
                    ("Lock-Token", "<\(lockToken)>"),
                    ("Content-Type", "text/xml; charset=\"utf-8\""),
                ], body: DavXML.lockResponse(token: lockToken))
            case "UNLOCK":
                try HTTPResponse.send(io, status: 204)
            case "PROPPATCH":
                let href = DavXML.encodeHref(prefix: token, segments: segments, isDirectory: false)
                try HTTPResponse.send(io, status: 207, headers: [
                    ("Content-Type", "text/xml; charset=\"utf-8\""),
                ], body: DavXML.proppatchResponse(href: href))
            default:
                try HTTPResponse.send(io, status: 501)
            }
        } catch let error where !(error is SocketIO.IOError) {
            if debugLogging { NSLog("dav: %@ %@ -> error %@", request.method, request.rawTarget, "\(error)") }
            try HTTPResponse.send(io, status: status(for: error))
        }
    }

    // MARK: - Methods

    private func propfind(_ request: HTTPRequest, path: [String], io: SocketIO) throws {
        let depth = request.header("depth") ?? "1"
        guard depth == "0" || depth == "1" else {
            try HTTPResponse.send(io, status: 403)
            return
        }

        let entry = try call { [backend] in try await backend.stat(path: path) }
        let quota: (total: UInt64, free: UInt64)? = path.isEmpty
            ? (try? call { [backend] in try await backend.quota() })
            : nil

        var responses = [DavXML.response(
            href: DavXML.encodeHref(prefix: token, segments: path, isDirectory: entry.isDirectory),
            entry: entry,
            quota: quota
        )]

        if depth == "1", entry.isDirectory {
            let children = try call { [backend] in try await backend.list(path: path) }
            for child in children {
                responses.append(DavXML.response(
                    href: DavXML.encodeHref(prefix: token, segments: path + [child.name], isDirectory: child.isDirectory),
                    entry: child
                ))
            }
        }

        try HTTPResponse.send(io, status: 207, headers: [
            ("Content-Type", "text/xml; charset=\"utf-8\""),
        ], body: DavXML.multistatus(responses))
    }

    private func get(_ request: HTTPRequest, path: [String], io: SocketIO) throws {
        let entry = try call { [backend] in try await backend.stat(path: path) }
        guard !entry.isDirectory else {
            try HTTPResponse.send(io, status: 403)
            return
        }

        var offsetValue: UInt64 = 0
        var lengthValue = entry.size
        var isPartial = false
        if let range = request.header("range"), range.hasPrefix("bytes=") {
            let spec = range.dropFirst(6).split(separator: ",")[0] // single range only
            let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
            let fromString = bounds.count > 0 ? String(bounds[0]) : ""
            let toString = bounds.count > 1 ? String(bounds[1]) : ""
            if fromString.isEmpty, let suffix = UInt64(toString) {
                offsetValue = entry.size > suffix ? entry.size - suffix : 0
                lengthValue = entry.size - offsetValue
            } else if let from = UInt64(fromString) {
                guard from < max(entry.size, 1) || entry.size == 0 else {
                    try HTTPResponse.send(io, status: 416, headers: [("Content-Range", "bytes */\(entry.size)")])
                    return
                }
                offsetValue = from
                if let to = UInt64(toString), to >= from {
                    lengthValue = min(to, entry.size == 0 ? 0 : entry.size - 1) - from + 1
                } else {
                    lengthValue = entry.size - from
                }
            }
            isPartial = true
        }
        let offset = offsetValue
        let length = lengthValue

        var headers: [(String, String)] = [
            ("Content-Length", "\(length)"),
            ("Accept-Ranges", "bytes"),
            ("ETag", DavXML.etag(size: entry.size, modified: entry.modified)),
        ]
        if isPartial {
            let last = length > 0 ? offset + length - 1 : offset
            headers.append(("Content-Range", "bytes \(offset)-\(last)/\(entry.size)"))
        }
        try HTTPResponse.send(io, status: isPartial ? 206 : 200, headers: headers, omitBody: true)

        guard request.method == "GET", length > 0 else { return }
        // Stream in backend-sized chunks; MTP tops out well below this.
        var sent: UInt64 = 0
        while sent < length {
            let want = Int(min(UInt64(4 << 20), length - sent))
            let readOffset = offset + sent
            let chunk = try call { [backend] in
                try await backend.read(path: path, offset: readOffset, length: want)
            }
            if chunk.isEmpty { break }
            try io.write(chunk)
            sent += UInt64(chunk.count)
        }
    }

    private func put(_ request: HTTPRequest, path: [String], io: SocketIO) throws {
        let existed = (try? call { [backend] in try await backend.stat(path: path) }) != nil
        // Land the body in a temp file: backends push whole files (MTP has no
        // partial writes) and may stream from disk.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try request.body.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        try call { [backend] in try await backend.write(path: path, contentsOf: temp) }
        try HTTPResponse.send(io, status: existed ? 204 : 201)
    }

    private func move(_ request: HTTPRequest, from: [String], io: SocketIO) throws {
        guard let destination = request.header("destination"),
              let destinationURL = URL(string: destination) else {
            try HTTPResponse.send(io, status: 400)
            return
        }
        var toSegments = destinationURL.path.split(separator: "/").map {
            String($0).removingPercentEncoding ?? String($0)
        }
        guard toSegments.first == token else {
            try HTTPResponse.send(io, status: 400)
            return
        }
        toSegments.removeFirst()
        let to = toSegments

        let overwrite = (request.header("overwrite") ?? "T").uppercased() != "F"
        let destinationExists = (try? call { [backend] in try await backend.stat(path: to) }) != nil
        if destinationExists {
            guard overwrite else {
                try HTTPResponse.send(io, status: 412)
                return
            }
            try call { [backend] in try await backend.delete(path: to) }
        }
        try call { [backend] in try await backend.move(from: from, to: to) }
        try HTTPResponse.send(io, status: destinationExists ? 204 : 201)
    }
}
