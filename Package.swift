// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UsageTracker",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "UsageTracker", targets: ["UsageTrackerApp"])
    ],
    targets: [
        .target(
            name: "UsageTrackerCore",
            path: "Sources/UsageTrackerCore"
        ),
        .executableTarget(
            name: "UsageTrackerApp",
            dependencies: ["UsageTrackerCore"],
            path: "Sources/UsageTrackerApp"
        ),
        .executableTarget(
            name: "UsageTrackerSelfTest",
            dependencies: ["UsageTrackerCore"],
            path: "Tools/SelfTest"
        )
    ]
)
