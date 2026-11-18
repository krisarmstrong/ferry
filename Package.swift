// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "Ferry",
  defaultLocalization: "en",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "DeviceKit", targets: ["DeviceKit"]),
    .library(name: "DeviceKitTestSupport", targets: ["DeviceKitTestSupport"]),
    .library(name: "FerryAgentCore", targets: ["FerryAgentCore"]),
    .library(name: "FerryIPC", targets: ["FerryIPC"]),
    .library(name: "FerryProviderCore", targets: ["FerryProviderCore"]),
    .library(name: "FerryUI", targets: ["FerryUI"]),
    .library(name: "MTPTransport", targets: ["MTPTransport"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2")
  ],
  targets: [
    .target(name: "DeviceKit"),
    .target(name: "DeviceKitTestSupport", dependencies: ["DeviceKit"]),
    .systemLibrary(name: "CLibMTP", pkgConfig: "libmtp", providers: [.brew(["libmtp"])]),
    .target(name: "MTPTransport", dependencies: ["DeviceKit", "CLibMTP"]),
    .target(name: "FerryAgentCore", dependencies: ["DeviceKit", "FerryIPC", "MTPTransport"]),
    .target(name: "FerryIPC", dependencies: ["DeviceKit"]),
    .target(name: "FerryProviderCore", dependencies: ["DeviceKit", "FerryIPC"]),
    .target(
      name: "FerryUI", dependencies: ["DeviceKit", "FerryIPC"],
      resources: [.process("Localizable.xcstrings"), .process("help.json")]),
    .executableTarget(
      name: "ferryctl",
      dependencies: [
        "DeviceKit", "MTPTransport",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]),
    .testTarget(
      name: "DeviceKitTests", dependencies: ["DeviceKit", "DeviceKitTestSupport"]),
    .testTarget(
      name: "MTPTransportTests",
      dependencies: ["MTPTransport", "DeviceKit", "DeviceKitTestSupport"]),
    .testTarget(
      name: "FerryAgentCoreTests",
      dependencies: [
        "FerryAgentCore", "FerryIPC", "DeviceKit", "DeviceKitTestSupport",
      ]),
    .testTarget(
      name: "FerryIPCTests", dependencies: ["FerryIPC", "DeviceKit", "DeviceKitTestSupport"]),
    .testTarget(
      name: "FerryProviderCoreTests",
      dependencies: ["FerryProviderCore", "FerryIPC", "DeviceKit", "DeviceKitTestSupport"]),
    .testTarget(
      name: "FerryUITests",
      dependencies: ["FerryUI", "FerryIPC", "DeviceKit", "DeviceKitTestSupport"]),
  ],
  swiftLanguageModes: [.v6]
)
