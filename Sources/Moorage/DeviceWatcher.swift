import Foundation
import IOKit
import IOKit.usb
import MTPKit

/// Watches the IO registry for MTP interfaces coming and going. Callbacks
/// arrive on the main queue with a full current-device snapshot; diffing is
/// the caller's job.
@MainActor
final class DeviceWatcher {

    var onChange: (@MainActor ([MTPDeviceRef]) -> Void)?

    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0

    func start() {
        let port = IONotificationPortCreate(kIOMainPortDefault)
        guard let port else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { context, iterator in
            // Drain or the notification never re-arms.
            while case let service = IOIteratorNext(iterator), service != 0 {
                IOObjectRelease(service)
            }
            guard let context else { return }
            let watcher = Unmanaged<DeviceWatcher>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                watcher.publish()
            }
        }

        // Two registrations, same callback: any USB interface arriving or
        // departing triggers a rescan. Filtering to MTP happens in the scan.
        IOServiceAddMatchingNotification(
            port, kIOMatchedNotification,
            IOServiceMatching("IOUSBHostInterface"),
            callback, context, &addedIterator
        )
        IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification,
            IOServiceMatching("IOUSBHostInterface"),
            callback, context, &removedIterator
        )
        // Prime both iterators (required to arm) and publish the initial state.
        drain(addedIterator)
        drain(removedIterator)
        publish()
    }

    func stop() {
        if addedIterator != 0 { IOObjectRelease(addedIterator); addedIterator = 0 }
        if removedIterator != 0 { IOObjectRelease(removedIterator); removedIterator = 0 }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
    }

    private func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }

    private func publish() {
        onChange?(MTPDeviceLocator.connectedDevices())
    }
}
