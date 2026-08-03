import Foundation
import IOUSBHost
import IOKit
import IOKit.usb

/// Raw bulk/interrupt USB plumbing for one MTP interface. Owns the exclusive
/// open on the interface; creating a second transport for the same device fails.
/// All calls are async wrappers over IOUSBHost's enqueue APIs; serialization is
/// the caller's job (MTPDevice actor).
public final class USBTransport: @unchecked Sendable {

    private let interface: IOUSBHostInterface
    private let bulkIn: IOUSBHostPipe
    private let bulkOut: IOUSBHostPipe
    private let interruptIn: IOUSBHostPipe?
    public let maxPacketSize: Int

    /// Opens the MTP interface for the given IOKit service. The service must be
    /// an IOUSBHostInterface registry entry. Exclusive-access failure here means
    /// another process (ptpcamera, Android File Transfer) holds the device.
    public init(interfaceService: io_service_t) throws {
        do {
            self.interface = try IOUSBHostInterface(__ioService: interfaceService, options: [], queue: nil, interestHandler: nil)
        } catch {
            let ns = error as NSError
            if ns.code == Int(kIOReturnExclusiveAccess) {
                throw MTPError(.deviceBusy("another process has claimed the device (Image Capture, Photos, or Android File Transfer)"))
            }
            throw MTPError(.usb("open interface failed: \(ns.localizedDescription)"))
        }

        // Walk the interface's endpoint descriptors for bulk-in, bulk-out and
        // the interrupt-in event pipe.
        var bulkInAddr: UInt8 = 0
        var bulkOutAddr: UInt8 = 0
        var interruptInAddr: UInt8 = 0
        var maxPacket = 512

        let config = interface.configurationDescriptor
        let ifaceDesc = interface.interfaceDescriptor
        var endpoint = IOUSBGetNextEndpointDescriptor(config, ifaceDesc, nil)
        while let ep = endpoint {
            let address = ep.pointee.bEndpointAddress
            let attributes = ep.pointee.bmAttributes & 0x03
            let isInput = (address & 0x80) != 0
            switch attributes {
            case 2: // bulk
                if isInput {
                    bulkInAddr = address
                    maxPacket = Int(ep.pointee.wMaxPacketSize)
                } else {
                    bulkOutAddr = address
                }
            case 3: // interrupt
                if isInput { interruptInAddr = address }
            default:
                break
            }
            endpoint = IOUSBGetNextEndpointDescriptor(config, ifaceDesc, UnsafeRawPointer(ep).assumingMemoryBound(to: IOUSBDescriptorHeader.self))
        }

        guard bulkInAddr != 0, bulkOutAddr != 0 else {
            throw MTPError(.usb("interface has no bulk endpoints; not an MTP data interface"))
        }

        do {
            self.bulkIn = try interface.copyPipe(withAddress: Int(bulkInAddr))
            self.bulkOut = try interface.copyPipe(withAddress: Int(bulkOutAddr))
            self.interruptIn = interruptInAddr != 0 ? try? interface.copyPipe(withAddress: Int(interruptInAddr)) : nil
        } catch {
            throw MTPError(.usb("open pipes failed: \((error as NSError).localizedDescription)"))
        }
        self.maxPacketSize = maxPacket
    }

    deinit {
        interface.destroy()
    }

    // MARK: - Bulk I/O

    /// Writes the whole buffer to bulk-out.
    public func write(_ data: Data, timeout: TimeInterval) async throws {
        let buffer = NSMutableData(data: data)
        _ = try await enqueue(pipe: bulkOut, data: buffer, timeout: timeout)
    }

    /// Sends a zero-length packet on bulk-out (data phase whose size is an
    /// exact multiple of the packet size needs one as terminator).
    public func writeZeroLengthPacket(timeout: TimeInterval) async throws {
        _ = try await enqueue(pipe: bulkOut, data: nil, timeout: timeout)
    }

    /// Reads up to `maxLength` from bulk-in. Returns whatever one transfer
    /// yields: a bulk read completes on a short packet or a full buffer.
    public func read(maxLength: Int, timeout: TimeInterval) async throws -> Data {
        guard let buffer = NSMutableData(length: maxLength) else {
            throw MTPError(.usb("buffer allocation failed"))
        }
        let transferred = try await enqueue(pipe: bulkIn, data: buffer, timeout: timeout)
        return buffer.subdata(with: NSRange(location: 0, length: transferred))
    }

    /// Reads one interrupt-in event transfer, if the device has an event pipe.
    /// Blocks until an event arrives; run from a dedicated task.
    public func readEvent(maxLength: Int = 64) async throws -> Data {
        guard let pipe = interruptIn else {
            throw MTPError(.notSupported("device has no interrupt endpoint"))
        }
        guard let buffer = NSMutableData(length: maxLength) else {
            throw MTPError(.usb("buffer allocation failed"))
        }
        let transferred = try await enqueue(pipe: pipe, data: buffer, timeout: 0)
        return buffer.subdata(with: NSRange(location: 0, length: transferred))
    }

    /// Discards any bytes left in the bulk-in pipe by a previous client that
    /// died mid-transaction, then clears endpoint stalls. Run before opening
    /// a session or stale containers masquerade as replies.
    public func drainStale() async {
        while true {
            guard let leftover = try? await read(maxLength: 64 << 10, timeout: 0.25), !leftover.isEmpty else { break }
        }
        clearStalls()
    }

    public func clearStalls() {
        try? bulkIn.__abort(with: .synchronous)
        try? bulkOut.__abort(with: .synchronous)
        try? bulkIn.clearStall()
        try? bulkOut.clearStall()
    }

    public func abortEventPipe() {
        try? interruptIn?.__abort(with: .synchronous)
    }

    private func enqueue(pipe: IOUSBHostPipe, data: NSMutableData?, timeout: TimeInterval) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try pipe.enqueueIORequest(with: data, completionTimeout: timeout) { status, bytesTransferred in
                    if status == kIOReturnSuccess {
                        continuation.resume(returning: bytesTransferred)
                    } else if status == kIOReturnAborted || status == kIOReturnNotResponding || status == kIOReturnNoDevice {
                        continuation.resume(throwing: MTPError(.deviceGone))
                    } else {
                        continuation.resume(throwing: MTPError(.usb("transfer failed: IOReturn 0x\(String(UInt32(bitPattern: status), radix: 16))")))
                    }
                }
            } catch {
                continuation.resume(throwing: MTPError(.usb("enqueue failed: \((error as NSError).localizedDescription)")))
            }
        }
    }
}
