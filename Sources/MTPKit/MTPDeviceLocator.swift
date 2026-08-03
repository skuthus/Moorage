import Foundation
import IOKit
import IOKit.usb

/// A connected MTP-capable device, discovered from the IO registry without
/// opening anything. Safe to build from any process; opening the interface
/// (USBTransport) is what takes exclusive access.
public struct MTPDeviceRef: Sendable, Equatable, Hashable {
    public let serial: String
    public let name: String
    public let vendorID: Int
    public let productID: Int
    public let locationID: UInt32

    public init(serial: String, name: String, vendorID: Int, productID: Int, locationID: UInt32) {
        self.serial = serial
        self.name = name
        self.vendorID = vendorID
        self.productID = productID
        self.locationID = locationID
    }

    /// Stable identity for mount URLs: serial when the device provides one,
    /// otherwise vid/pid/port location.
    public var urlHost: String {
        if !serial.isEmpty { return serial }
        return String(format: "%04x.%04x.%08x", vendorID, productID, locationID)
    }

    /// Identity is the mount host: the same physical device keeps the same
    /// identity across replugs, even though its USB locationID changes. Without
    /// this, a replug looks like one device leaving and a different one
    /// arriving, desyncing mount state from the device list.
    public static func == (lhs: MTPDeviceRef, rhs: MTPDeviceRef) -> Bool {
        lhs.urlHost == rhs.urlHost
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(urlHost)
    }

    public var mtpURL: URL {
        URL(string: "mtp://\(urlHost)")!
    }
}

public enum MTPDeviceLocator {

    /// Still Image class / PTP subclass / PTP protocol — the standard MTP
    /// interface triple.
    private static let mtpClassTriples: [(UInt8, UInt8, UInt8)] = [
        (6, 1, 1)
    ]

    /// Many devices (Kindle Paperwhite: 255/255/0) expose MTP as a
    /// vendor-specific interface instead, marked only by the interface name
    /// string "MTP".
    private static func isVendorMTP(class cls: UInt8, interfaceName: String?) -> Bool {
        cls == 0xFF && interfaceName?.uppercased() == "MTP"
    }

    /// All MTP-capable interfaces currently in the IO registry.
    public static func connectedDevices() -> [MTPDeviceRef] {
        var found = [MTPDeviceRef]()
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOUSBHostInterface")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let ref = deviceRef(forInterfaceService: service) {
                if !found.contains(ref) { found.append(ref) }
            }
        }
        return found
    }

    /// The io_service_t for the MTP interface of the device with the given URL
    /// host identity. Caller owns the returned reference (IOObjectRelease).
    public static func findInterfaceService(urlHost: String) -> io_service_t? {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOUSBHostInterface")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            if let ref = deviceRef(forInterfaceService: service), ref.urlHost == urlHost {
                return service // transfer ownership
            }
            IOObjectRelease(service)
        }
        return nil
    }

    private static func deviceRef(forInterfaceService service: io_service_t) -> MTPDeviceRef? {
        guard let cls: Int = property(service, "bInterfaceClass"),
              let sub: Int = property(service, "bInterfaceSubClass"),
              let proto: Int = property(service, "bInterfaceProtocol") else {
            return nil
        }
        let interfaceName: String? = property(service, "kUSBString") ?? property(service, "USB Interface Name")
        let standardMTP = mtpClassTriples.contains(where: { $0 == (UInt8(cls), UInt8(sub), UInt8(proto)) })
        guard standardMTP || isVendorMTP(class: UInt8(cls), interfaceName: interfaceName) else {
            return nil
        }

        // Identity lives on the parent IOUSBHostDevice node.
        var device: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &device) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(device) }

        let serial: String = property(device, "USB Serial Number") ?? ""
        let product: String = property(device, "USB Product Name") ?? "MTP Device"
        let vendorID: Int = property(device, "idVendor") ?? 0
        let productID: Int = property(device, "idProduct") ?? 0
        let locationID: Int = property(device, "locationID") ?? 0

        return MTPDeviceRef(
            serial: serial, name: product,
            vendorID: vendorID, productID: productID,
            locationID: UInt32(truncatingIfNeeded: locationID)
        )
    }

    private static func property<T>(_ entry: io_registry_entry_t, _ key: String) -> T? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return value.takeRetainedValue() as? T
    }
}
