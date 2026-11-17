// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "Ferry",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "DeviceKit", targets: ["DeviceKit"]),
    .library(name: "DeviceKitTestSupport", targets: ["DeviceKitTestSupport"]),
    .library(name: "FerryAgentCore", targets: ["FerryAgentCore"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2")
  ],
  targets: [
    .target(name: "DeviceKit"),
    .target(name: "DeviceKitTestSupport", dependencies: ["DeviceKit"]),
    .systemLibrary(name: "CLibMTP", pkgConfig: "libmtp", providers: [.brew(["libmtp"])]),
    .target(name: "MTPTransport", dependencies: ["DeviceKit", "CLibMTP"]),
    .target(name: "FerryAgentCore", dependencies: ["DeviceKit", "MTPTransport"]),
    .executableTarget(
      name: "ferryctl",
      dependencies: [
        "DeviceKit", "MTPTransport",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]),
    .testTarget(
      name: "DeviceKitTests", dependencies: ["DeviceKit", "DeviceKitTestSupport"]),
    .testTarget(name: "MTPTransportTests", dependencies: ["MTPTransport", "DeviceKit"]),
    .testTarget(
      name: "FerryAgentCoreTests",
      dependencies: ["FerryAgentCore", "DeviceKit", "DeviceKitTestSupport"]),
  ],
  swiftLanguageModes: [.v6]
)
