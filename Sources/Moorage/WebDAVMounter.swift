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

    private(set) var active = [String: Active]() // keyed by urlHost

    static let mountRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Moorage", isDirectory: true)

    enum MountError: Error, CustomStringConvertible {
        case failed(String)
        var description: String {
            if case .failed(let message) = self { return message }
            return "mount failed"
        }
    }

    func isMounted(_ device: MTPDeviceRef) -> Bool {
        active[device.urlHost] != nil
    }

    func mountPoint(for device: MTPDeviceRef) -> URL? {
        active[device.urlHost]?.mountPoint
    }

    func mount(_ device: MTPDeviceRef) async throws -> URL {
        if let existing = active[device.urlHost] { return existing.mountPoint }

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

        let result = try await run("/sbin/mount_webdav", ["-v", dirName, server.url.absoluteString, mountPoint.path])
        DebugLog.log("mount: mount_webdav exit \(result.status) \(result.output)")
        guard result.status == 0 else {
            server.stop()
            await backend.shutdown()
            try? FileManager.default.removeItem(at: mountPoint)
            throw MountError.failed(result.output.isEmpty ? "mount_webdav exited \(result.status)" : result.output)
        }

        active[device.urlHost] = Active(device: device, backend: backend, server: server, mountPoint: mountPoint)
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
