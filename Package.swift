// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "EC25Toolbox",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "EC25Toolbox", targets: ["EC25Toolbox"]),
        .executable(name: "EC25IKEHelper", targets: ["EC25IKEHelper"])
    ],
    targets: [
        .target(
            name: "EC25IKEHelperProtocol",
            path: "Sources/EC25IKEHelperProtocol"
        ),
        .target(
            name: "CVoWiFiCrypto",
            path: "Sources/CVoWiFiCrypto",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "EC25Toolbox",
            dependencies: ["CVoWiFiCrypto", "EC25IKEHelperProtocol"],
            path: "Sources/EC25Toolbox",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("IOUSBHost"),
                .linkedFramework("Security"),
                .linkedFramework("Network"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .executableTarget(
            name: "EC25IKEHelper",
            dependencies: ["EC25IKEHelperProtocol"],
            path: "Sources/EC25IKEHelper",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .testTarget(
            name: "EC25ToolboxTests",
            dependencies: ["EC25Toolbox"],
            path: "Tests/EC25ToolboxTests"
        )
    ]
)
