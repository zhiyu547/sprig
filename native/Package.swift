// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GitToolNative",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "GitTool", targets: ["GitTool"]), .executable(name: "GitProbe", targets: ["GitProbe"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "GitCore"),
        .executableTarget(name: "GitTool", dependencies: ["GitCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "GitProbe", dependencies: ["GitCore"]),
        .testTarget(name: "GitCoreTests", dependencies: ["GitCore"]),
        .testTarget(name: "GitToolTests", dependencies: ["GitTool", "GitCore"])
    ]
)
