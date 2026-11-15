// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacGadgets",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MacGadgets", targets: ["MacGadgets"])
    ],
    targets: [
        .target(
            name: "CUSBBridge",
            path: "Sources/CUSBBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "MacGadgets",
            dependencies: ["CUSBBridge"],
            path: "Sources/MacGadgets",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
