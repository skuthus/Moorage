# Known Pitfalls

Mapped before first line of code, 2026-08-02. Each has an owner strategy; none is unsolved.

## 1. Nobody mounts MTP on macOS, on purpose

Google (Android File Transfer) and OpenMTP both chose transfer windows over mounts because MTP fights filesystem semantics. We accept the harder road for the better UX. Consequences below.

## 2. MTP protocol limits

- Single session, one command in flight. No parallel I/O, ever.
- Reads OK: GetPartialObject is widely supported.
- Writes are whole-object: SendPartialObject is rare in the wild. No in-place edit, no append.
- No atomic rename guarantees.

**Strategy:** read-optimized. `fetchContents` downloads whole objects on demand. Writes upload the whole object; "editing in place" is really delete + full re-upload (replaceContents). File Provider shows its own progress UI during transfers.

## 3. Finder junk and eager downloads

QuickLook can try to thumbnail media, which for a video means downloading the whole file.

**Strategy:** File Provider keeps .DS_Store and similar in the system's own metadata layer, so junk never becomes provider items or reaches the device. We advertise no thumbnails. The bigger watch item is any process that bulk-reads the tree and forces materialization; the `NSFileProviderExtensionNonMaterializingProcessNames` default can block named offenders if needed.

## 4. macOS grabs the phone first

ptpcamera / Image Capture / Photos auto-claim MTP/PTP devices on plug. Android File Transfer's helper daemon (if installed) does the same. Result: "device busy", the extension can't open the USB interface. This is the number one support-ticket generator.

**Strategy:** the extension reports serverUnreachable when it can't claim the device; the menu bar surfaces a plain-language reason. Handle on day one, not after launch.

## 5. Mount tech dead ends (why we're on File Provider)

macFUSE needs a kext; Apple Silicon kexts need Reduced Security toggled in Recovery Mode. Instant dealbreaker.

FSKit was built first and abandoned. Two stacked walls on macOS 26:
- The Swift `@main UnaryFileSystemExtension` entry crashes on launch (`AppExtension.main` -> "Unrecognized extension type"), greying out the Settings toggle. Our hand-assembled SwiftPM appex didn't reproduce what the Xcode File System Extension target wires up.
- Even correctly-built third-party FSKit modules are rejected by `fskitd` on macOS 26 (`entitlement no`, extensionKit errorDomain Code=2). Confirmed by multiple projects (loaf, macFUSE's FSKit backend, OpenZFS). Apple bug, no fix as of 26.5.

File Provider was attempt two: registered cleanly, but a hand-assembled (SwiftPM, no Xcode) appex never gets its principal class instantiated; fileproviderd shows a Loading... folder forever. Modern app extensions effectively require Xcode's target wiring.

The final architecture drops extensions entirely: the app serves a token-guarded WebDAV server on 127.0.0.1 and mounts it with /sbin/mount_webdav, which works unprivileged onto user-owned directories. A real volume, all userspace, all testable from the terminal. (fuse-t proved the shape with NFS.)

## 5a. USB from a sandboxed extension (the open question)

The File Provider extension runs sandboxed and needs to talk to the phone over IOUSBHost. It carries `com.apple.security.device.usb`. Whether the sandbox actually grants a File Provider appex raw USB interface access is the one thing on-device testing must confirm. If it's blocked, the fallback is an XPC broker in the non-sandboxed main app that owns the USB session and streams bytes to the extension. Direct access is the clean path; we try it first.

## 6. Device quirks are our problem now

Choosing pure Swift over libmtp means we do not inherit libmtp's 20-year quirk database. Phones must be unlocked and in File Transfer mode; bad cables present as protocol errors.

Two quirks already earned on real hardware (Kindle Paperwhite):
- Vendor-specific MTP interface (class 255/255/0, interface string "MTP") instead of the standard Still Image 6/1/1 triple. The locator accepts both.
- Strict PIMA 15740 transaction IDs: commands outside a session (GetDeviceInfo, OpenSession) must carry TID 0 or the device answers ParameterNotSupported. Phones forgive this; Kindles don't.

Also learned: a client that dies mid-transaction leaves stale containers in the bulk-in pipe, which the next session misreads as its own replies. Connect now drains the pipe and clears stalls first, and data reads skip stale containers by transaction ID.

**Strategy:** strict-spec core plus a quirk table that grows from bug reports. libmtp's quirk list is readable for reference (reading LGPL source for facts is fine; no code copying).

## 7. Honest speed ceiling

MTP tops out around 30-40 MB/s regardless of implementation. "Fast" for Moorage means zero added latency: cached metadata, async everything, priority queue so Finder interactions preempt background work. Never promise USB3 numbers.

## 8. Cable yank mid-write

Unplug during upload leaves a truncated file on the device with no rollback.

**Strategy:** unplug removes the domain; File Provider marks the in-flight operation failed and retries on reconnect. MTP's whole-object writes mean a failed upload leaves the old object intact until the new one fully lands.

## 9. Enumeration at scale

A phone with 15k photos: GetObjectHandles per folder plus per-object GetObjectInfo is thousands of round trips.

**Strategy:** background tree walk on connect, lazy per-folder hydration, persist the cache keyed by device + storage ID so reconnects are warm.

## 10. Multiple storages

Internal storage and SD card are separate MTP storage IDs. They appear as top-level folders within the one device domain, not separate domains, so they share the single USB session.

## 11. Boring but mandatory

- Developer ID signing + notarization (pipeline exists from Envy).
- Login item via SMAppService, off by default.
- File Provider appex packaging from SwiftPM output, scripted. No provisioning profile needed (File Provider is unrestricted), unlike the abandoned FSKit path.
- Name collision checked: Moorage clean on GitHub as of 2026-08-02.
