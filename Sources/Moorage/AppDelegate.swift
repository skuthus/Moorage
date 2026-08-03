import AppKit
@preconcurrency import FileProvider
import ServiceManagement
import MTPKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let watcher = DeviceWatcher()
    private let mounter = WebDAVMounter()
    private var devices = [MTPDeviceRef]()
    /// Devices that failed to mount, with the reason, for menu display.
    private var errors = [String: String]()
    /// Devices we've auto-opened a Finder window for this attach.
    private var revealed = Set<String>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = MenuBarIcon.image(mounted: false)
            button.image?.accessibilityDescription = "Moorage"
        }
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self

        removeLegacyFileProviderDomains()

        watcher.onChange = { [weak self] current in
            self?.devicesChanged(current)
        }

        // Clear any orphaned mounts from a previous run before we start
        // watching — a stale mount hangs Finder, so this must happen first.
        Task {
            await mounter.sweepOrphanMounts()
            watcher.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher.stop()
        let mounter = self.mounter
        // Blocking teardown: unmount cleanly before the process dies.
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await mounter.unmountAll()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 10)
    }

    /// Earlier Moorage builds used File Provider; clear any domains they left
    /// so Finder doesn't show a dead sidebar entry.
    private func removeLegacyFileProviderDomains() {
        NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
            NSLog("Moorage cleanup: %d legacy domain(s), error=%@", domains.count, error.map { "\($0)" } ?? "none")
            for domain in domains {
                NSFileProviderManager.remove(domain, mode: .removeAll) { _, removeError in
                    NSLog("Moorage cleanup: removed %@ error=%@", domain.identifier.rawValue, removeError.map { "\($0)" } ?? "none")
                }
            }
        }
    }

    // MARK: - Device flow

    private func devicesChanged(_ current: [MTPDeviceRef]) {
        let previous = devices
        devices = current

        for gone in previous where !current.contains(gone) {
            errors.removeValue(forKey: gone.urlHost)
            revealed.remove(gone.urlHost)
            Task { await mounter.deviceGone(gone) }
        }
        for arrived in current where !previous.contains(arrived) {
            autoMount(arrived)
        }
        updateIcon()
    }

    private func autoMount(_ device: MTPDeviceRef) {
        Task {
            do {
                let mountPoint = try await mounter.mount(device)
                errors.removeValue(forKey: device.urlHost)
                // First mount for this attach: open it so the device is
                // immediately visible.
                if !revealed.contains(device.urlHost) {
                    revealed.insert(device.urlHost)
                    NSWorkspace.shared.open(mountPoint)
                }
            } catch WebDAVMounter.MountError.inProgress {
                // Another attempt for this device is already running; ignore.
            } catch {
                errors[device.urlHost] = "\(error)"
            }
            updateIcon()
        }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        // Authoritative: reflect whether anything is actually mounted, not
        // whether the current scan happens to list a mounted device.
        button.image = MenuBarIcon.image(mounted: mounter.hasActiveMounts)
        button.image?.accessibilityDescription = "Moorage"
    }

    // MARK: - Actions

    /// A device from the scan or, failing that, the current mounts.
    private func device(forHost host: String) -> MTPDeviceRef? {
        devices.first { $0.urlHost == host } ?? mounter.mountedDevices.first { $0.urlHost == host }
    }

    @objc private func toggleMount(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? String,
              let device = device(forHost: host) else { return }
        Task {
            if mounter.isMounted(device) {
                await mounter.unmount(device)
                revealed.remove(device.urlHost)
            } else {
                autoMount(device)
            }
            updateIcon()
        }
    }

    @objc private func revealDevice(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? String,
              let device = device(forHost: host),
              let mountPoint = mounter.mountPoint(for: device) else { return }
        NSWorkspace.shared.open(mountPoint)
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Moorage: login item toggle failed: \(error)")
        }
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}

// MARK: - Menu

extension AppDelegate: NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Show every device the scan sees, plus any that are mounted even if
        // the scan momentarily doesn't list them (e.g. mid-replug), deduped by
        // identity. This keeps a live mount visible in the menu.
        var shown = devices
        for mounted in mounter.mountedDevices where !shown.contains(mounted) {
            shown.append(mounted)
        }

        if shown.isEmpty {
            let item = NSMenuItem(title: "No MTP device connected", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            let hint = NSMenuItem(title: "Plug in a device and choose File Transfer", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }

        for device in shown {
            let mounted = mounter.isMounted(device)
            let header = NSMenuItem(title: device.name, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            if mounted {
                let reveal = NSMenuItem(title: "Show in Finder", action: #selector(revealDevice(_:)), keyEquivalent: "")
                reveal.target = self
                reveal.representedObject = device.urlHost
                reveal.indentationLevel = 1
                menu.addItem(reveal)
            }

            let toggle = NSMenuItem(
                title: mounted ? "Eject" : "Mount",
                action: #selector(toggleMount(_:)), keyEquivalent: ""
            )
            toggle.target = self
            toggle.representedObject = device.urlHost
            toggle.indentationLevel = 1
            menu.addItem(toggle)

            if let error = errors[device.urlHost] {
                let errorItem = NSMenuItem(title: error, action: nil, keyEquivalent: "")
                errorItem.isEnabled = false
                errorItem.indentationLevel = 1
                menu.addItem(errorItem)
            }
        }

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Moorage", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
}
