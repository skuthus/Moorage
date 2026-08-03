import Foundation
import DavKit
import MTPKit

/// One connected device = one DavServer + one mount_webdav volume under
/// ~/Moorage/<Device>. Unprivileged: mount_webdav happily mounts a localhost
/// URL onto a user-owned directory.
@MainActor
final class WebDAVMounter {

    struct Active {
        let device: MTPDeviceRef
        let backend: MTPDavBackend
        let server: DavServer
        let mountPoint: URL
    }

    /// True once a volume is mounted at `url`. Reads the kernel mount table
    /// (MNT_NOWAIT, no refresh) rather than stat-ing the path: stat on a path
    /// that mount_webdav is mid-mounting routes through the stalling WebDAV
    /// filesystem and blocks for the whole ~90s, freezing the caller. The mount
    /// table is populated by mount(2) as soon as the volume registers.
    static func isMountPoint(_ url: URL) -> Bool {
        let target = url.standardizedFileURL.path
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return false }
        for i in 0..<Int(count) {
            var entry = buffer[i]
            let name = withUnsafeBytes(of: &entry.f_mntonname) { raw -> String in
                guard let base = raw.baseAddress else { return "" }
                return String(cString: base.assumingMemoryBound(to: CChar.self))
            }
            if name == target { return true }
        }
        return false
    }

    private(set) var active = [String: Active]() // keyed by urlHost
    /// Hosts with a mount attempt in flight. MTP allows one exclusive USB
    /// claim per device, so two concurrent attempts collide and both fail —
    /// this guard admits exactly one attempt per device at a time.
    private var mounting = Set<String>()

    static let mountRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Moorage", isDirectory: true)

    enum MountError: Error, CustomStringConvertible {
        case failed(String)
        case inProgress
        var description: String {
            switch self {
            case .failed(let message): return message
            case .inProgress: return "mount already in progress"
            }
        }
    }

    func isMounted(_ device: MTPDeviceRef) -> Bool {
        active[device.urlHost] != nil
    }

    func isMounted(host: String) -> Bool {
        active[host] != nil
    }

    func mountPoint(for device: MTPDeviceRef) -> URL? {
        active[device.urlHost]?.mountPoint
    }

    /// Whether anything is mounted — the authoritative source for the menu bar
    /// indicator, independent of the transient device scan.
    var hasActiveMounts: Bool { !active.isEmpty }

    /// The devices currently mounted, as captured at mount time.
    var mountedDevices: [MTPDeviceRef] { active.values.map(\.device) }

    func mount(_ device: MTPDeviceRef) async throws -> URL {
        if let existing = active[device.urlHost] { return existing.mountPoint }
        // Runs to the first `await` synchronously on the main actor, so this
        // check-and-insert is atomic against other concurrent mount() calls:
        // the second caller sees the flag and bails instead of racing for USB.
        guard !mounting.contains(device.urlHost) else { throw MountError.inProgress }
        mounting.insert(device.urlHost)
        defer { mounting.remove(device.urlHost) }

        let backend = MTPDavBackend(urlHost: device.urlHost)
        // Eager connect, with retries: right after plug-in the device may not
        // be ready yet, and Image Capture's daemon transiently claims new MTP
        // devices before releasing them. One instant attempt would fail races
        // that resolve themselves within seconds.
        var volumeName: String?
        for attempt in 1...5 {
            do {
                DebugLog.log("mount: prepare attempt \(attempt) for \(device.name)")
                volumeName = try await backend.prepare()
                DebugLog.log("mount: prepared, volume '\(volumeName ?? "")'")
                break
            } catch {
                DebugLog.log("mount: prepare attempt \(attempt) failed: \(error)")
                await backend.shutdown()
                if attempt < 5 {
                    try? await Task.sleep(for: .seconds(Double(attempt)))
                }
            }
        }
        guard let volumeName else {
            throw MountError.failed("Could not open the device. Unlock it, choose File Transfer mode, and make sure no other app (Image Capture, Photos, Android File Transfer) has claimed it.")
        }

        let server = DavServer(backend: backend)
        server.debugLogging = true
        server.logHandler = { DebugLog.log("dav " + $0) }
        try server.start()

        let dirName = sanitize(volumeName.isEmpty ? device.name : volumeName)
        var mountPoint = Self.mountRoot.appendingPathComponent(dirName, isDirectory: true)
        var n = 2
        while active.values.contains(where: { $0.mountPoint == mountPoint }) {
            mountPoint = Self.mountRoot.appendingPathComponent("\(dirName) \(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        // A previous run that died uncleanly can leave a dead webdav mount on
        // this path; mounting over it would stack. Sweep first.
        _ = try? await run("/sbin/umount", ["-f", mountPoint.path])
        _ = try? await run("/sbin/umount", ["-f", mountPoint.path])

        // mount_webdav establishes the volume within a second or two but then
        // lingers ~90s before it exits (a webdavfs quirk, reproducible even
        // against a trivial local server). Waiting on its exit would make every
        // mount feel like a 90-second hang, so instead launch it and poll for
        // the volume to actually appear.
        let webdav = Process()
        webdav.executableURL = URL(fileURLWithPath: "/sbin/mount_webdav")
        // -S suppresses mount_webdav's authentication and "server not
        // responding" dialogs. Without it, a background (LSUIElement) app has
        // no UI session to show those dialogs, so mount_webdav waits ~90s for
        // one before giving up and mounting anyway. Our server is local and
        // never needs auth, so suppressing is pure win — and it makes the mount
        // appear in ~1s instead of 90s.
        webdav.arguments = ["-S", "-v", dirName, server.url.absoluteString, mountPoint.path]
        webdav.terminationHandler = { _ in }   // reap when it eventually exits
        do {
            try webdav.run()
        } catch {
            server.stop()
            await backend.shutdown()
            try? FileManager.default.removeItem(at: mountPoint)
            throw MountError.failed("could not launch mount_webdav: \(error.localizedDescription)")
        }

        var mounted = false
        for _ in 0..<100 {   // up to ~20s
            if Self.isMountPoint(mountPoint) { mounted = true; break }
            if !webdav.isRunning, webdav.terminationStatus != 0 { break } // failed early
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard mounted else {
            if webdav.isRunning { webdav.terminate() }
            server.stop()
            await backend.shutdown()
            try? FileManager.default.removeItem(at: mountPoint)
            throw MountError.failed("mount_webdav did not mount the volume")
        }
        DebugLog.log("mount: volume up at \(mountPoint.path)")

        active[device.urlHost] = Active(device: device, backend: backend, server: server, mountPoint: mountPoint)

        // Keep Spotlight off the volume as a fire-and-forget nicety. This is
        // never awaited in the mount path: `mdutil` on a WebDAV mount can hang,
        // and blocking here would leave the mount untracked (no menu bar
        // update, no auto-reveal). The volume's .metadata_never_index file is
        // the real, synchronous opt-out.
        let path = mountPoint.path
        Task.detached { [weak self] in _ = try? await self?.run("/usr/bin/mdutil", ["-i", "off", path]) }

        return mountPoint
    }

    func unmount(_ device: MTPDeviceRef, force: Bool = false) async {
        guard let entry = active[device.urlHost] else { return }
        var args = force ? ["-f"] : [String]()
        args.append(entry.mountPoint.path)
        let result = try? await run("/sbin/umount", args)
        if result?.status != 0, !force {
            // Busy volume: force it rather than leave a zombie.
            _ = try? await run("/sbin/umount", ["-f", entry.mountPoint.path])
        }
        entry.server.stop()
        await entry.backend.shutdown()
        try? FileManager.default.removeItem(at: entry.mountPoint)
        active.removeValue(forKey: device.urlHost)
    }

    /// Cable yanked: the volume is dead; force-clean everything.
    func deviceGone(_ device: MTPDeviceRef) async {
        await unmount(device, force: true)
    }

    func unmountAll() async {
        for entry in active.values {
            await unmount(entry.device)
        }
    }

    /// Force-unmount any Moorage WebDAV mounts left by a previous run. Mounts
    /// outlive the process, so an unclean exit (crash, or a dev `killall`)
    /// orphans them: their local server is dead, and Finder hangs forever on
    /// the mount point. Run this at launch, before anything else, so a stale
    /// mount never wedges the session.
    func sweepOrphanMounts() async {
        let rootPath = Self.mountRoot.path
        let listing = (try? await run("/sbin/mount", [])) ?? (status: 0, output: "")
        for line in listing.output.split(separator: "\n") {
            guard line.contains("webdav"), line.contains(rootPath),
                  let onRange = line.range(of: " on "),
                  let tag = line.range(of: " (webdav") else { continue }
            let path = String(line[onRange.upperBound..<tag.lowerBound])
            _ = try? await run("/sbin/umount", ["-f", path])
        }
        // Remove leftover empty mount-point directories.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: rootPath)) ?? []
        for name in names {
            let dir = Self.mountRoot.appendingPathComponent(name, isDirectory: true)
            if (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }

    private func sanitize(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "MTP Device" : cleaned
    }

    private func run(_ tool: String, _ args: [String]) async throws -> (status: Int32, output: String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { finished in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: (finished.terminationStatus, output))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
