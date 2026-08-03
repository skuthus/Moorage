import Foundation

public struct MTPDeviceInfo: Sendable {
    public let manufacturer: String
    public let model: String
    public let version: String
    public let serialNumber: String
    public let operationsSupported: Set<UInt16>
    public let eventsSupported: Set<UInt16>

    public func supports(_ op: PTP.Op) -> Bool {
        operationsSupported.contains(op.rawValue)
    }

    public static func parse(_ data: Data) throws -> MTPDeviceInfo {
        var r = PTPReader(data)
        _ = try r.u16()        // StandardVersion
        _ = try r.u32()        // VendorExtensionID
        _ = try r.u16()        // VendorExtensionVersion
        _ = try r.string()     // VendorExtensionDesc
        _ = try r.u16()        // FunctionalMode
        let ops = try r.u16Array()
        let events = try r.u16Array()
        _ = try r.u16Array()   // DevicePropertiesSupported
        _ = try r.u16Array()   // CaptureFormats
        _ = try r.u16Array()   // ImageFormats (playback)
        let manufacturer = try r.string()
        let model = try r.string()
        let version = try r.string()
        let serial = try r.string()
        return MTPDeviceInfo(
            manufacturer: manufacturer, model: model, version: version, serialNumber: serial,
            operationsSupported: Set(ops), eventsSupported: Set(events)
        )
    }
}

public struct MTPStorageInfo: Sendable {
    public let storageID: UInt32
    public let maxCapacity: UInt64
    public let freeSpace: UInt64
    public let description: String
    public let isReadOnly: Bool

    public static func parse(_ data: Data, storageID: UInt32) throws -> MTPStorageInfo {
        var r = PTPReader(data)
        _ = try r.u16()                  // StorageType
        _ = try r.u16()                  // FilesystemType
        let accessCapability = try r.u16()
        let maxCapacity = try r.u64()
        let freeSpace = try r.u64()
        _ = try r.u32()                  // FreeSpaceInObjects
        let description = try r.string()
        return MTPStorageInfo(
            storageID: storageID,
            maxCapacity: maxCapacity,
            freeSpace: freeSpace,
            description: description.isEmpty ? "Storage" : description,
            isReadOnly: accessCapability != 0 // 0 = read-write
        )
    }
}

public struct MTPObjectInfo: Sendable {
    public let handle: UInt32
    public let storageID: UInt32
    public let format: UInt16
    public let compressedSize: UInt32
    public let parentHandle: UInt32
    public let filename: String
    public let dateCreated: Date?
    public let dateModified: Date?

    public init(handle: UInt32, storageID: UInt32, format: UInt16, compressedSize: UInt32, parentHandle: UInt32, filename: String, dateCreated: Date?, dateModified: Date?) {
        self.handle = handle
        self.storageID = storageID
        self.format = format
        self.compressedSize = compressedSize
        self.parentHandle = parentHandle
        self.filename = filename
        self.dateCreated = dateCreated
        self.dateModified = dateModified
    }

    public var isFolder: Bool { format == PTP.Format.association }
    /// 0xFFFFFFFF in ObjectInfo means "file is 4 GiB or larger; ask object props".
    public var sizeNeedsPropQuery: Bool { compressedSize == 0xFFFF_FFFF }

    public static func parse(_ data: Data, handle: UInt32) throws -> MTPObjectInfo {
        var r = PTPReader(data)
        let storageID = try r.u32()
        let format = try r.u16()
        _ = try r.u16()                  // ProtectionStatus
        let size = try r.u32()
        _ = try r.u16()                  // ThumbFormat
        _ = try r.u32()                  // ThumbCompressedSize
        _ = try r.u32()                  // ThumbPixWidth
        _ = try r.u32()                  // ThumbPixHeight
        _ = try r.u32()                  // ImagePixWidth
        _ = try r.u32()                  // ImagePixHeight
        _ = try r.u32()                  // ImageBitDepth
        let parent = try r.u32()
        _ = try r.u16()                  // AssociationType
        _ = try r.u32()                  // AssociationDesc
        _ = try r.u32()                  // SequenceNumber
        let filename = try r.string()
        let created = try r.string()
        let modified = try r.string()
        return MTPObjectInfo(
            handle: handle, storageID: storageID, format: format, compressedSize: size,
            parentHandle: parent, filename: filename,
            dateCreated: parsePTPDate(created), dateModified: parsePTPDate(modified)
        )
    }

    /// Dataset for SendObjectInfo when uploading a new object.
    public static func makeDataset(storageID: UInt32, parentHandle: UInt32, filename: String, size: UInt64, isFolder: Bool, modified: Date?) -> Data {
        var w = PTPWriter()
        w.u32(storageID)
        w.u16(isFolder ? PTP.Format.association : PTP.Format.undefined)
        w.u16(0)                                     // ProtectionStatus
        w.u32(size >= UInt64(UInt32.max) ? 0xFFFF_FFFF : UInt32(size))
        w.u16(0); w.u32(0); w.u32(0); w.u32(0)       // thumb fields
        w.u32(0); w.u32(0); w.u32(0)                 // image fields
        w.u32(parentHandle)
        w.u16(isFolder ? 1 : 0)                      // AssociationType: GenericFolder
        w.u32(0)                                     // AssociationDesc
        w.u32(0)                                     // SequenceNumber
        w.string(filename)
        w.string("")                                 // DateCreated
        w.string(modified.map(formatPTPDate) ?? "")
        w.string("")                                 // Keywords
        return w.data
    }
}

// PTP dates are "YYYYMMDDThhmmss" with optional ".s" and timezone suffix.
private let ptpDateParser: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd'T'HHmmss"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    return f
}()

func parsePTPDate(_ s: String) -> Date? {
    guard s.count >= 15 else { return nil }
    return ptpDateParser.date(from: String(s.prefix(15)))
}

func formatPTPDate(_ d: Date) -> String {
    ptpDateParser.string(from: d)
}
