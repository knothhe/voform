// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Voform",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Voform", targets: ["Voform"])
    ],
    targets: [
        .executableTarget(
            name: "Voform",
            path: "Sources/Voform",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                .linkedFramework("Carbon")
            ]
        ),
        .testTarget(name: "VoformTests", dependencies: ["Voform"])
    ],
    swiftLanguageModes: [.v5]
)
