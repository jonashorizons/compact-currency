// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CompactCurrency",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CompactCurrency", targets: ["CompactCurrency"])],
    targets: [
        .target(name: "CurrencyCore"),
        .executableTarget(name: "CompactCurrency", dependencies: ["CurrencyCore"], resources: [.process("Resources")]),
        .testTarget(name: "CurrencyCoreTests", dependencies: ["CurrencyCore"])
    ]
)
