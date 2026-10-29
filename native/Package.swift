// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MenuGitCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "MenuGitCore", targets: ["MenuGitCore"])],
    targets: [
        .target(name: "MenuGitCore"),
        .testTarget(name: "MenuGitCoreTests", dependencies: ["MenuGitCore"])
    ]
)
