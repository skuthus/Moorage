# Moorage Design

Decisions locked 2026-08-02. Change only with a written reason here.

## Product shape

Menu bar app (LSUIElement), no windows, no dock icon. Plug in an MTP device, it mounts as a real volume under ~/Moorage and a Finder window opens on it. Menu shows connected devices, Mount/Eject, "Show in Finder", launch-at-login toggle, quit. That is the whole UI.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Finder integration | Local WebDAV bridge + mount_webdav | The app serves the MTP tree over a token-guarded 127.0.0.1 WebDAV server (pure Swift, in-process) and mounts it with macOS's built-in mount_webdav: a real volume, unprivileged, zero extensions, zero Xcode. Same architecture fuse-t proved with NFS. |
| ~~File Provider~~ (rejected) | ~~NSFileProviderReplicatedExtension~~ | Second attempt. Hand-built appexes never launch their principal class outside Xcode's extension target wiring; this Mac has CLT only. |
| ~~FSKit~~ (rejected) | ~~FSUnaryFileSystem~~ | First attempt. Third-party FSKit modules are broken on macOS 26 (Apple bug: fskitd rejects unprivileged clients) and the Swift @main entry crashes. See PITFALLS. |
| MTP layer | Pure Swift over IOUSBHost | Zero dependencies, tiny binary, full control. libmtp rejected: LGPL dylib + libusb bundling, C interop, threading flakiness. We absorb device quirks ourselves as reports come in. |
| Language | Swift, strict concurrency | House standard. |
| Build | SwiftPM + Scripts/, no Xcode project | Same pattern as Envy. Single-binary app bundle assembled and signed by build script. |
| License | MIT | Contributor-friendly, no bundled LGPL code to complicate it. |
| Min target | macOS 26.0 | Matches the rest of the house stack; nothing in the WebDAV architecture needs it, so it can drop if demand appears. |
| Name | Moorage | Where a vessel moors: the phone docks to the mac. Collision-checked on GitHub 2026-08-02, clean. |

## Architecture

One process, four layers:

```
Moorage.app (one process, no extensions)
├── MTPKit          MTP protocol over IOUSBHost: session, tree, transfers
├── DavKit          WebDAV class-2 server on 127.0.0.1 (BSD sockets, no deps)
├── MTPDavBackend   bridges DavKit's backend protocol onto MTPKit
└── WebDAVMounter   mount_webdav / umount per device, ~/Moorage/<Name>
```

- **MTPKit**: MTP container protocol (OpenSession, GetStorageIDs/Info, GetObjectHandles/Info, GetPartialObject, SendObjectInfo/SendObject, DeleteObject, MoveObject, SetObjectPropValue, events). Actor-owned single USB session. Survived all three architectures unchanged.
- **DavKit**: OPTIONS/PROPFIND/GET+Range/PUT/DELETE/MKCOL/MOVE/LOCK/UNLOCK/PROPPATCH against any async `DavBackend`. Thread-per-connection blocking I/O; random UUID path token so other local processes can't reach the tree; fake-but-valid LOCK so webdavfs mounts read-write. `InMemoryBackend` lets the whole stack be tested with no device.
- **MTPDavBackend**: path-to-handle resolution with per-directory caching, Finder-junk shadowing in RAM (.DS_Store/._* never reach the device), whole-file PUT = delete + SendObject (MTP's only write mode).
- **Moorage.app**: IOKit plug/unplug notifications; on attach: connect, serve, mount, open Finder window. Menu: Mount/Eject, Show in Finder, Launch at Login, Quit.

One volume per device: storages (internal + SD card) are top-level folders sharing the single MTP session.

## Why a WebDAV bridge beats the "native" APIs here

WebDAV's semantics are almost exactly MTP's semantics: GET+Range = GetPartialObject, whole-file PUT = SendObject, and macOS's webdavfs client stages edited files locally and uploads whole on close, which is precisely the staging dance MTP requires. mount_webdav mounts localhost URLs as a plain user onto user-owned directories: no root, no kext, no extension approval, no provisioning profile, no notarization gates beyond the app itself. Every layer is testable from the terminal without a device.

## Performance rules

Same philosophy as Envy: the interactive path never waits on sync work.

- Metadata cached in MTPDavBackend keyed by path/handle; repeat lookups don't re-hit the device.
- Big folders (15k-photo DCIM) enumerate with bulk GetObjectHandles per folder, object info fetched lazily.
- One in-flight MTP command at a time (protocol limit), enforced by actor isolation.
- webdavfs fetches contents only when files are opened, so browsing never triggers bulk transfers. Finder junk (.DS_Store, ._AppleDouble) is swallowed into a RAM shadow and never reaches the device.
- No thumbnail generation that would trigger full-file downloads.

## Distribution

Developer ID signed + notarized, same pipeline as Envy (Team ID and notary profile already set up). DMG download from a project page. Free, MIT.

## Non-goals

- Windows/Linux support
- Photo import UI, file browser UI, any window
- iOS devices (they are not MTP)
- Beating MTP wire speed (~30-40 MB/s ceiling is the protocol's, not ours)
