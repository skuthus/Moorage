# Moorage

Mount your Android phone in Finder. Small, fast, free.

Moorage is a macOS menu bar app that mounts MTP devices (Android phones, tablets, cameras, e-readers) as real Finder volumes. Plug in, unlock the phone, and it appears on your desktop like any drive. No transfer window, no drivers, no kernel extensions.

## Why

macOS has no native MTP support. The existing options are transfer-window apps (Android File Transfer, OpenMTP) that make you work inside their UI. Moorage takes the other road: a true Finder mount, powered by Apple's modern FSKit userspace filesystem API, with nothing on screen but a menu bar item.

## Status

Early development. Not yet usable. See [docs/DESIGN.md](docs/DESIGN.md) for architecture and [docs/PITFALLS.md](docs/PITFALLS.md) for the known hard problems and how we plan to handle them.

## Requirements

- macOS 15.4 or later (FSKit)
- Apple Silicon or Intel
- A device that speaks MTP, set to File Transfer mode

## Design goals

1. **Real mount.** Files show up in Finder, Spotlight-quiet, junk-file-free.
2. **Small.** Pure Swift, zero third-party dependencies, tiny binary.
3. **Fast.** Metadata cached on connect, async enumeration, never blocks Finder on a device round-trip. MTP's wire speed is the only ceiling.
4. **Silent.** Launches at login, lives in the menu bar, one menu: activity, safe eject, quit.

## Building

SwiftPM plus build scripts, no Xcode project. Details land in `Scripts/` as the build pipeline takes shape.

## License

MIT. See [LICENSE](LICENSE).
