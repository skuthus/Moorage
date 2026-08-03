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
  sessions, stale-pipe drain on connect.
- Finder junk (.DS_Store, ._AppleDouble) swallowed in RAM, never sent to
  the device.
- MoorageSelfCheck: 50 checks covering MTP codec and the WebDAV server,
  plus `scan`, `probe [read]`, and `--serve-demo` (mountable in-memory
  device) diagnostics.
- Project scaffold: design doc, pitfall map, MIT license.
