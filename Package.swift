// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TranslateBar",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "TranslateBar", targets: ["TranslateBar"])],
    targets: [
        .executableTarget(name: "TranslateBar"),
        .testTarget(name: "TranslateBarTests", dependencies: ["TranslateBar"])
    ]
)
