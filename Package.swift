// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Alcove",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Alcove", targets: ["Alcove"])],
    targets: [.executableTarget(name: "Alcove", path: "Sources/Alcove")],
    swiftLanguageModes: [.v5]
)
