// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CMStormLights",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "CMStormLights",
            path: "Sources/CMStormLights",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
