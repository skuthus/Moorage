import Foundation

/// Little-endian reader for PTP datasets.
public struct PTPReader {
    public let data: Data
    public private(set) var offset: Int

    public init(_ data: Data, at offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    public var remaining: Int { data.count - offset }

    public mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw MTPError(.protocolViolation("dataset truncated")) }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    public mutating func u16() throws -> UInt16 {
        try UInt16(u8()) | (UInt16(u8()) << 8)
    }

    public mutating func u32() throws -> UInt32 {
        try UInt32(u16()) | (UInt32(u16()) << 16)
    }

    public mutating func u64() throws -> UInt64 {
        try UInt64(u32()) | (UInt64(u32()) << 32)
    }

    public mutating func u128Truncated() throws -> UInt64 {
        let low = try u64()
        _ = try u64()
        return low
    }

    /// PTP string: u8 char count (incl. NUL), then UTF-16LE code units.
    public mutating func string() throws -> String {
        let count = Int(try u8())
        if count == 0 { return "" }
        var units = [UInt16]()
        units.reserveCapacity(count)
        for _ in 0..<count { units.append(try u16()) }
        if units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    public mutating func u16Array() throws -> [UInt16] {
        let count = Int(try u32())
        guard remaining >= count * 2 else { throw MTPError(.protocolViolation("array truncated")) }
        var out = [UInt16]()
        out.reserveCapacity(count)
        for _ in 0..<count { out.append(try u16()) }
        return out
    }

    public mutating func u32Array() throws -> [UInt32] {
        let count = Int(try u32())
        guard remaining >= count * 4 else { throw MTPError(.protocolViolation("array truncated")) }
        var out = [UInt32]()
        out.reserveCapacity(count)
        for _ in 0..<count { out.append(try u32()) }
        return out
    }

    public mutating func skip(_ n: Int) throws {
        guard remaining >= n else { throw MTPError(.protocolViolation("dataset truncated")) }
        offset += n
    }
}

/// Little-endian writer for PTP datasets.
public struct PTPWriter {
    public private(set) var data = Data()

    public init() {}

    public mutating func u8(_ v: UInt8) { data.append(v) }

    public mutating func u16(_ v: UInt16) {
        data.append(UInt8(v & 0xFF))
        data.append(UInt8(v >> 8))
    }

    public mutating func u32(_ v: UInt32) {
        u16(UInt16(v & 0xFFFF))
        u16(UInt16(v >> 16))
    }

    public mutating func u64(_ v: UInt64) {
        u32(UInt32(v & 0xFFFF_FFFF))
        u32(UInt32(v >> 32))
    }

    public mutating func string(_ s: String) {
        if s.isEmpty {
            u8(0)
            return
        }
        var units = Array(s.utf16)
        // PTP strings are capped at 255 code units including the terminator.
        if units.count > 254 { units = Array(units.prefix(254)) }
        units.append(0)
        u8(UInt8(units.count))
        for unit in units { u16(unit) }
    }
}
