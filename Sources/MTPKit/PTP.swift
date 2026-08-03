import Foundation

/// PTP/MTP wire constants. MTP (Media Transfer Protocol) is PTP (ISO 15740)
/// plus Microsoft's 0x98xx extension opcodes and 0xDCxx object properties.
public enum PTP {

    /// Container types, byte 4-5 of every bulk transfer.
    public enum ContainerType: UInt16, Sendable {
        case command = 1
        case data = 2
        case response = 3
        case event = 4
    }

    public enum Op: UInt16, Sendable {
        case getDeviceInfo = 0x1001
        case openSession = 0x1002
        case closeSession = 0x1003
        case getStorageIDs = 0x1004
        case getStorageInfo = 0x1005
        case getNumObjects = 0x1006
        case getObjectHandles = 0x1007
        case getObjectInfo = 0x1008
        case getObject = 0x1009
        case deleteObject = 0x100B
        case sendObjectInfo = 0x100C
        case sendObject = 0x100D
        case moveObject = 0x1019
        case copyObject = 0x101A
        case getPartialObject = 0x101B
        // MTP extensions
        case getObjectPropsSupported = 0x9801
        case getObjectPropDesc = 0x9802
        case getObjectPropValue = 0x9803
        case setObjectPropValue = 0x9804
    }

    public enum Response: UInt16, Sendable {
        case ok = 0x2001
        case generalError = 0x2002
        case sessionNotOpen = 0x2003
        case invalidTransactionID = 0x2004
        case operationNotSupported = 0x2005
        case parameterNotSupported = 0x2006
        case incompleteTransfer = 0x2007
        case invalidStorageID = 0x2008
        case invalidObjectHandle = 0x2009
        case storeFull = 0x200C
        case objectWriteProtected = 0x200D
        case storeReadOnly = 0x200E
        case accessDenied = 0x200F
        case deviceBusy = 0x2019
        case invalidParentObject = 0x201A
        case sessionAlreadyOpen = 0x201E
        case transactionCancelled = 0x201F
        case invalidObjectPropCode = 0xA801
        case objectPropNotSupported = 0xA80A
        case unknown = 0xFFFF

        public init(code: UInt16) {
            self = Response(rawValue: code) ?? .unknown
        }
    }

    public enum Event: UInt16, Sendable {
        case cancelTransaction = 0x4001
        case objectAdded = 0x4002
        case objectRemoved = 0x4003
        case storeAdded = 0x4004
        case storeRemoved = 0x4005
        case deviceInfoChanged = 0x4008
        case storageInfoChanged = 0x400C
    }

    /// Object format codes. Association = folder; everything else is a file to us.
    public enum Format {
        public static let undefined: UInt16 = 0x3000
        public static let association: UInt16 = 0x3001
    }

    /// MTP object property codes.
    public enum ObjectProp {
        public static let objectSize: UInt16 = 0xDC04
        public static let objectFileName: UInt16 = 0xDC07
    }

    /// Special values on the wire.
    public static let allStorageIDs: UInt32 = 0xFFFF_FFFF
    public static let allFormats: UInt32 = 0
    public static let rootParentHandle: UInt32 = 0xFFFF_FFFF
    /// Container length field when the payload exceeds 32 bits (streamed until short packet).
    public static let lengthOverflow: UInt32 = 0xFFFF_FFFF
}

public struct MTPError: Error, CustomStringConvertible, Sendable {
    public enum Kind: Sendable {
        case usb(String)
        case protocolViolation(String)
        case response(PTP.Response)
        case deviceGone
        case deviceBusy(String)
        case notSupported(String)
    }
    public let kind: Kind

    public init(_ kind: Kind) { self.kind = kind }

    public var description: String {
        switch kind {
        case .usb(let s): return "USB error: \(s)"
        case .protocolViolation(let s): return "MTP protocol violation: \(s)"
        case .response(let r): return "MTP response 0x\(String(r.rawValue, radix: 16)) (\(r))"
        case .deviceGone: return "Device disconnected"
        case .deviceBusy(let s): return "Device busy: \(s)"
        case .notSupported(let s): return "Not supported: \(s)"
        }
    }

    /// Map to a POSIX errno for FSKit replies.
    public var posixCode: Int32 {
        switch kind {
        case .usb: return EIO
        case .protocolViolation: return EIO
        case .deviceGone: return ENXIO
        case .deviceBusy: return EBUSY
        case .notSupported: return ENOTSUP
        case .response(let r):
            switch r {
            case .storeFull: return ENOSPC
            case .objectWriteProtected, .storeReadOnly, .accessDenied: return EACCES
            case .invalidObjectHandle, .invalidParentObject: return ENOENT
            case .deviceBusy: return EBUSY
            case .operationNotSupported, .objectPropNotSupported: return ENOTSUP
            default: return EIO
            }
        }
    }
}
