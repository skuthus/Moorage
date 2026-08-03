import Foundation

/// A PTP bulk container: 12-byte header (length u32, type u16, code u16,
/// transaction ID u32) followed by payload.
public struct PTPContainer: Sendable {
    public static let headerSize = 12

    public let length: UInt32
    public let type: PTP.ContainerType
    public let code: UInt16
    public let transactionID: UInt32
    public let payload: Data

    public init(type: PTP.ContainerType, code: UInt16, transactionID: UInt32, payload: Data = Data()) {
        self.type = type
        self.code = code
        self.transactionID = transactionID
        self.payload = payload
        let total = UInt64(Self.headerSize) + UInt64(payload.count)
        self.length = total > UInt64(UInt32.max) ? PTP.lengthOverflow : UInt32(total)
    }

    /// Command container with up to 5 u32 parameters.
    public static func command(_ op: PTP.Op, transactionID: UInt32, params: [UInt32] = []) -> PTPContainer {
        precondition(params.count <= 5)
        var w = PTPWriter()
        for p in params { w.u32(p) }
        return PTPContainer(type: .command, code: op.rawValue, transactionID: transactionID, payload: w.data)
    }

    public func encoded() -> Data {
        var w = PTPWriter()
        w.u32(length)
        w.u16(type.rawValue)
        w.u16(code)
        w.u32(transactionID)
        var out = w.data
        out.append(payload)
        return out
    }

    /// Encode only the 12-byte header for an explicit payload size; used when
    /// streaming a data phase without materializing the whole payload.
    public static func header(type: PTP.ContainerType, code: UInt16, transactionID: UInt32, payloadSize: UInt64) -> Data {
        var w = PTPWriter()
        let total = UInt64(headerSize) + payloadSize
        w.u32(total > UInt64(UInt32.max) ? PTP.lengthOverflow : UInt32(total))
        w.u16(type.rawValue)
        w.u16(code)
        w.u32(transactionID)
        return w.data
    }

    /// Parse a header from the first 12 bytes; payload is whatever follows in `data`.
    public static func parse(_ data: Data) throws -> PTPContainer {
        guard data.count >= headerSize else {
            throw MTPError(.protocolViolation("container shorter than header (\(data.count) bytes)"))
        }
        var r = PTPReader(data)
        let length = try r.u32()
        let rawType = try r.u16()
        guard let type = PTP.ContainerType(rawValue: rawType) else {
            throw MTPError(.protocolViolation("unknown container type 0x\(String(rawType, radix: 16))"))
        }
        let code = try r.u16()
        let tid = try r.u32()
        return PTPContainer(
            parsedLength: length, type: type, code: code, transactionID: tid,
            payload: data.count > headerSize ? data.subdata(in: (data.startIndex + headerSize)..<data.endIndex) : Data()
        )
    }

    private init(parsedLength: UInt32, type: PTP.ContainerType, code: UInt16, transactionID: UInt32, payload: Data) {
        self.length = parsedLength
        self.type = type
        self.code = code
        self.transactionID = transactionID
        self.payload = payload
    }

    /// Response parameters (u32s after the header).
    public func responseParams() -> [UInt32] {
        var r = PTPReader(payload)
        var params = [UInt32]()
        while r.remaining >= 4 {
            if let v = try? r.u32() { params.append(v) } else { break }
        }
        return params
    }
}
