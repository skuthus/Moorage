import Foundation

/// A parsed HTTP/1.1 request. Header keys lowercased.
struct HTTPRequest {
    let method: String
    let rawTarget: String
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// Decoded path segments of the request target, query stripped.
    /// "/a%20b/c/" -> ["a b", "c"]
    var pathSegments: [String] {
        var target = rawTarget
        if let q = target.firstIndex(of: "?") { target = String(target[..<q]) }
        return target.split(separator: "/").map {
            String($0).removingPercentEncoding ?? String($0)
        }
    }

    var wantsCollection: Bool {
        var target = rawTarget
        if let q = target.firstIndex(of: "?") { target = String(target[..<q]) }
        return target.hasSuffix("/")
    }

    /// Reads one request off the connection. Returns nil on clean EOF between
    /// requests (keep-alive connection closed by client).
    static func read(from io: SocketIO) throws -> HTTPRequest? {
        let requestLine: String
        do {
            requestLine = try io.readLine()
        } catch SocketIO.IOError.closed {
            return nil
        }
        if requestLine.isEmpty {
            // Stray CRLF between pipelined requests; try once more.
            return try read(from: io)
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        var headers = [String: String]()
        while true {
            let line = try io.readLine()
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        // The interim response contract: client waits for 100 before sending
        // a large body (mount_webdav PUTs use this).
        if headers["expect"]?.lowercased().contains("100-continue") == true {
            try io.write("HTTP/1.1 100 Continue\r\n\r\n")
        }

        var body = Data()
        if let te = headers["transfer-encoding"], te.lowercased().contains("chunked") {
            while true {
                let sizeLine = try io.readLine()
                let size = Int(sizeLine.split(separator: ";").first.map(String.init) ?? "0", radix: 16) ?? 0
                if size == 0 {
                    // Consume trailer lines through the final blank line.
                    while !(try io.readLine()).isEmpty {}
                    break
                }
                body.append(try io.read(exactly: size))
                _ = try io.readLine() // chunk-terminating CRLF
            }
        } else if let lengthValue = headers["content-length"], let length = Int(lengthValue), length > 0 {
            body = try io.read(exactly: length)
        }

        return HTTPRequest(method: method, rawTarget: target, headers: headers, body: body)
    }
}

/// Response writer: status + headers + body, keep-alive friendly.
struct HTTPResponse {
    static let statusText: [Int: String] = [
        100: "Continue", 200: "OK", 201: "Created", 204: "No Content",
        206: "Partial Content", 207: "Multi-Status",
        301: "Moved Permanently", 304: "Not Modified",
        400: "Bad Request", 403: "Forbidden", 404: "Not Found",
        405: "Method Not Allowed", 409: "Conflict", 412: "Precondition Failed",
        415: "Unsupported Media Type", 416: "Range Not Satisfiable",
        423: "Locked", 500: "Internal Server Error", 501: "Not Implemented",
        503: "Service Unavailable", 507: "Insufficient Storage",
    ]

    static func send(_ io: SocketIO, status: Int, headers: [(String, String)] = [], body: Data = Data(), omitBody: Bool = false) throws {
        var head = "HTTP/1.1 \(status) \(statusText[status] ?? "Status")\r\n"
        head += "Server: Moorage\r\n"
        head += "Connection: keep-alive\r\n"
        var hasLength = false
        for (name, value) in headers {
            if name.lowercased() == "content-length" { hasLength = true }
            head += "\(name): \(value)\r\n"
        }
        if !hasLength {
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "\r\n"
        try io.write(head)
        if !omitBody, !body.isEmpty {
            try io.write(body)
        }
    }
}
