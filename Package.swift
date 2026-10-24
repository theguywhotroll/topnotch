// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TopNotch",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "TopNotch", targets: ["TopNotch"])],
    targets: [.executableTarget(name: "TopNotch", path: "Sources/TopNotch")],
    swiftLanguageModes: [.v5]
)
