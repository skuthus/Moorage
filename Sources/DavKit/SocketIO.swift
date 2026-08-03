import Foundation

/// Blocking, buffered I/O over a socket fd. One instance per connection,
/// owned by that connection's thread.
final class SocketIO {
    let fd: Int32
    private var buffer = Data()
    private static let readChunk = 64 << 10

    enum IOError: Error {
        case closed
        case timeout
        case tooLong
    }

    init(fd: Int32) {
        self.fd = fd
        // Never SIGPIPE the process on a client that went away.
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        // Reap dead connections instead of parking threads forever.
        var tv = timeval(tv_sec: 300, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit {
        close(fd)
    }

    private func fill() throws {
        var chunk = [UInt8](repeating: 0, count: Self.readChunk)
        let n = recv(fd, &chunk, chunk.count, 0)
        if n > 0 {
            buffer.append(contentsOf: chunk[0..<n])
        } else if n == 0 {
            throw IOError.closed
        } else {
            throw (errno == EAGAIN || errno == EWOULDBLOCK) ? IOError.timeout : IOError.closed
        }
    }

    /// Reads a CRLF-terminated line (CRLF stripped). Lines are ASCII headers;
    /// cap length defensively.
    func readLine() throws -> String {
        while true {
            if let range = buffer.range(of: Data([13, 10])) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                guard line.count <= 16384 else { throw IOError.tooLong }
                return String(decoding: line, as: UTF8.self)
            }
            guard buffer.count <= 65536 else { throw IOError.tooLong }
            try fill()
        }
    }

    func read(exactly n: Int) throws -> Data {
        while buffer.count < n {
            try fill()
        }
        let out = buffer.prefix(n)
        buffer.removeFirst(n)
        return Data(out)
    }

    func write(_ data: Data) throws {
        var sent = 0
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while sent < data.count {
                let n = send(fd, base + sent, data.count - sent, 0)
                if n <= 0 { throw IOError.closed }
                sent += n
            }
        }
    }

    func write(_ string: String) throws {
        try write(Data(string.utf8))
    }
}
