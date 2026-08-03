// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "Moorage",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        // MTP/PTP protocol over IOUSBHost. No UI, no server.
        .target(
            name: "MTPKit",
            linkerSettings: [
                .linkedFramework("IOUSBHost"),
                .linkedFramework("IOKit"),
            ]
        ),
        // Local WebDAV server: how the device tree becomes a mounted volume,
        // via macOS's built-in mount_webdav. No MTP dependency; any DavBackend.
        .target(
            name: "DavKit"
        ),
        // Menu bar app: device watching, WebDAV serving, mounting.
        .executableTarget(
            name: "Moorage",
            dependencies: ["MTPKit", "DavKit"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                // Only for removing stale domains left by the abandoned
                // File Provider build.
                .linkedFramework("FileProvider"),
            ]
        ),
        // Terminal test harness: MTP codec + WebDAV server tests, no device.
        .executableTarget(
            name: "MoorageSelfCheck",
            dependencies: ["MTPKit", "DavKit"]
        ),
        // Renders the app icon in code, per size. No image assets.
        .executableTarget(
            name: "IconGenerator"
        ),
    ],
    swiftLanguageModes: [.v6]
)
