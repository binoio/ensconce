// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Ensconce",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Everything testable: window enumeration, hide strategies, process control.
        // Must stay free of Sparkle so the tests never spin up an updater.
        .target(name: "WindowList"),
        .executableTarget(
            name: "Ensconce",
            dependencies: [
                "WindowList",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                // Sparkle.framework is embedded in Contents/Frameworks by Scripts/build.sh
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(name: "WindowListTests", dependencies: ["WindowList"]),
    ]
)
