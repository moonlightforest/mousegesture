// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MouseGesture",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MouseGesture", targets: ["MouseGestureApp"])
    ],
    targets: [
        .target(name: "MouseGestureCore"),
        .executableTarget(
            name: "MouseGestureApp",
            dependencies: ["MouseGestureCore"]
        ),
        .testTarget(
            name: "MouseGestureCoreTests",
            dependencies: ["MouseGestureCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
