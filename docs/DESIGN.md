# Moorage Design

Decisions locked 2026-08-02. Change only with a written reason here.

## Product shape

Menu bar app (LSUIElement), no windows, no dock icon. Plug in an MTP device, it mounts as a Finder volume. Menu shows connected devices, transfer activity, safe eject, launch-at-login toggle, quit. That is the whole UI.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Mount tech | FSKit (macOS 15.4+) | True Finder volume, userspace, no kext, notarizes clean. macFUSE rejected: kext requires Reduced Security on Apple Silicon. FileProvider rejected: sidebar "location" not a real volume, heavier sync ceremony. |
| MTP layer | Pure Swift over IOUSBHost | Zero dependencies, tiny binary, full control. libmtp rejected: LGPL dylib + libusb bundling, C interop, threading flakiness. We absorb device quirks ourselves as reports come in. |
| Language | Swift, strict concurrency | House standard. |
| Build | SwiftPM + Scripts/, no Xcode project | Same pattern as Envy. FSKit extension (.appex) assembled and signed by build script. |
| License | MIT | Contributor-friendly, no bundled LGPL code to complicate it. |
| Min target | macOS 15.4 | FSKit floor. |
| Name | Moorage | Where a vessel moors: the phone docks to the mac. Collision-checked on GitHub 2026-08-02, clean. |

## Architecture

Three targets:

```
Moorage.app                    menu bar app, device watcher, lifecycle
└── MoorageFS.appex            FSKit FSUnaryFileSystem extension, one instance per storage
    └── MTPKit                 library: MTP protocol over IOUSBHost, no UI, no FSKit
```

- **MTPKit**: MTP container protocol (opcodes: OpenSession, GetStorageIDs, GetStorageInfo, GetObjectHandles, GetObjectInfo, GetObject, GetPartialObject, SendObjectInfo, SendObject, DeleteObject, MoveObject, GetDeviceInfo, CloseSession, plus events). Owns the single USB session and a serial command queue. All async.
- **MoorageFS**: translates FSKit operations onto MTPKit. Read path streams via GetPartialObject. Write path stages to a local temp file, pushes whole object on close (MTP has no partial writes on most devices). Metadata tree cached on mount, invalidated by MTP events (ObjectAdded, ObjectRemoved) when the device sends them.
- **Moorage.app**: IOKit USB matching notifications for plug/unplug, claims device (kicks ptpcamera politely, see PITFALLS), asks FSKit to mount each storage (internal + SD card mount separately), menu bar status, SMAppService login item.

## Performance rules

Same philosophy as Envy: the interactive path never waits on sync work.

- Directory tree enumerated in the background on connect; Finder browsing hits cache only.
- Big folders (15k-photo DCIM) enumerate with bulk GetObjectHandles per folder, object info fetched lazily in batches.
- One in-flight MTP command at a time (protocol limit); queue is priority-ordered so a Finder stat beats a background prefetch.
- Volume mounts with Spotlight indexing off; .DS_Store and ._AppleDouble writes are swallowed, never sent to the device.
- No thumbnail generation that would trigger full-file downloads.

## Distribution

Developer ID signed + notarized, same pipeline as Envy (Team ID and notary profile already set up). DMG download from a project page. Free, MIT.

## Non-goals

- Windows/Linux support
- Photo import UI, file browser UI, any window
- iOS devices (they are not MTP)
- Beating MTP wire speed (~30-40 MB/s ceiling is the protocol's, not ours)
