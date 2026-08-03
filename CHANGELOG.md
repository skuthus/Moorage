# Changelog

All notable changes to Moorage.

## [Unreleased]

- Working end to end against a real Kindle Paperwhite: auto-mount on plug,
  browse, byte-exact reads, capacity display, auto-opened Finder window.
- Final architecture (third attempt): zero extensions. The menu bar app
  serves the MTP tree over a token-guarded localhost WebDAV server (DavKit,
  pure Swift) and mounts it with the system's mount_webdav. FSKit (Apple bug
  on macOS 26) and File Provider (appex launch requires Xcode target wiring)
  are documented dead ends in docs/PITFALLS.md.
- MTPKit: pure Swift MTP/PTP over IOUSBHost. Kindle quirks handled:
  vendor-specific MTP interface detection, strict transaction-ID-0 outside
  sessions, stale-pipe drain on connect. FIFO bus lock makes multi-phase
  transactions atomic under webdavfs's concurrent requests (actor isolation
  alone reenters at every await).
- Full write lifecycle verified on-device: paste, rename, delete, mkdir,
  nested ops, 2 MB binary round-trip byte-identical.
- Single-storage devices (Kindle) mount the storage as the volume root; no
  read-only "Internal Storage" wrapper to trip Finder pastes.
- Mount robustness: retry with backoff at attach (Image Capture races),
  stale-mount sweep before mounting, debug log at ~/Library/Logs/Moorage.log.
- Finder junk (.DS_Store, ._AppleDouble) swallowed in RAM, never sent to
  the device.
- MoorageSelfCheck: 50 checks covering MTP codec and the WebDAV server,
  plus `scan`, `probe [read]`, and `--serve-demo` (mountable in-memory
  device) diagnostics.
- Project scaffold: design doc, pitfall map, MIT license.
