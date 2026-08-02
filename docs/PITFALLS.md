# Known Pitfalls

Mapped before first line of code, 2026-08-02. Each has an owner strategy; none is unsolved.

## 1. Nobody mounts MTP on macOS, on purpose

Google (Android File Transfer) and OpenMTP both chose transfer windows over mounts because MTP fights filesystem semantics. We accept the harder road for the better UX. Consequences below.

## 2. MTP protocol limits

- Single session, one command in flight. No parallel I/O, ever.
- Reads OK: GetPartialObject is widely supported.
- Writes are whole-object: SendPartialObject is rare in the wild. No in-place edit, no append.
- No atomic rename guarantees.

**Strategy:** read-optimized mount. Writes stage to a local temp file and upload complete on close. Saving a file "in place" on the device is really delete + full re-upload; surface progress in the menu bar so it never looks hung.

## 3. Finder is a hostile tenant

Finder writes .DS_Store and ._AppleDouble files everywhere, Spotlight wants to index the volume, QuickLook will download entire videos to thumbnail them.

**Strategy:** swallow junk-file writes (report success, send nothing), mount with indexing disabled, no eager thumbnails. Test with a DCIM folder full of large videos.

## 4. macOS grabs the phone first

ptpcamera / Image Capture / Photos auto-claim MTP/PTP devices on plug. Android File Transfer's helper daemon (if installed) does the same. Result: "device busy", mount fails mysteriously. This is the number one support-ticket generator.

**Strategy:** detect the claimant, take over where the OS allows, otherwise tell the user exactly what is holding the device and how to release it. Handle on day one, not after launch.

## 5. Mount tech dead ends

macFUSE needs a kext; Apple Silicon kexts need Reduced Security toggled in Recovery Mode. Instant dealbreaker for "easy install". FSKit is the only clean path and floors us at macOS 15.4. FSKit is young: sparse docs, few shipped examples, API may shift. Budget time for spelunking.

## 6. Device quirks are our problem now

Choosing pure Swift over libmtp means we do not inherit libmtp's 20-year quirk database. Samsung, Xiaomi, Pixel all have MTP oddities. Phones must be unlocked and in File Transfer mode; bad cables present as protocol errors.

**Strategy:** strict-spec core plus a small per-vendor quirk table that grows from bug reports. Clear menu bar messaging for locked-phone and wrong-mode states. libmtp's quirk list is readable for reference (reading LGPL source for facts is fine; no code copying).

## 7. Honest speed ceiling

MTP tops out around 30-40 MB/s regardless of implementation. "Fast" for Moorage means zero added latency: cached metadata, async everything, priority queue so Finder interactions preempt background work. Never promise USB3 numbers.

## 8. Cable yank mid-write

Unplug during upload leaves a truncated file on the device with no rollback.

**Strategy:** menu bar shows in-flight transfers, safe-eject affordance, on reconnect detect and offer to re-push interrupted uploads.

## 9. Enumeration at scale

A phone with 15k photos: GetObjectHandles per folder plus per-object GetObjectInfo is thousands of round trips.

**Strategy:** background tree walk on connect, lazy per-folder hydration, persist the cache keyed by device + storage ID so reconnects are warm.

## 10. Multiple storages

Internal storage and SD card are separate MTP storage IDs. Each mounts as its own volume; eject must be per-storage.

## 11. Boring but mandatory

- Developer ID signing + notarization (pipeline exists from Envy).
- Login item via SMAppService, off by default until first successful mount.
- FSKit extension entitlements and appex packaging from SwiftPM output, scripted.
- Name collision checked: Moorage clean on GitHub as of 2026-08-02.
