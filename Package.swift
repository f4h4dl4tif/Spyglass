// swift-tools-version:5.9
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "Spyglass",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Spyglass",
            path: "Sources/Spyglass",
            swiftSettings: [.unsafeFlags(["-Osize", "-wmo",
                                           // Constant values for App Intents (Shortcuts/Siri) metadata, read by Scripts/intents-metadata.sh
                                           "-emit-const-values-path", root + "/.build/Spyglass.swiftconstvalues",
                                           "-Xfrontend", "-const-gather-protocols-file", "-Xfrontend", root + "/Scripts/const-protocols.json"],
                                          .when(configuration: .release))],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-dead_strip"], .when(configuration: .release)),
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("Vision"),
                .linkedFramework("PDFKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("UserNotifications"),
            ]
        )
    ]
)
