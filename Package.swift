// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "Ferry",
  defaultLocalization: "en",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "ADBTransport", targets: ["ADBTransport"]),
    .library(name: "DeviceKit", targets: ["DeviceKit"]),
    .library(name: "DeviceKitTestSupport", targets: ["DeviceKitTestSupport"]),
    .library(name: "FerryAgentCore", targets: ["FerryAgentCore"]),
    .library(name: "FerryIPC", targets: ["FerryIPC"]),
    .library(name: "FerryProviderCore", targets: ["FerryProviderCore"]),
    .library(name: "FerrySyncCore", targets: ["FerrySyncCore"]),
    .library(name: "FerryText", targets: ["FerryText"]),
    .library(name: "FerryUI", targets: ["FerryUI"]),
    .library(name: "MTPTransport", targets: ["MTPTransport"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2")
  ],
  targets: [
    .target(name: "ADBTransport", dependencies: ["DeviceKit"]),
    .target(name: "DeviceKit"),
    .target(name: "DeviceKitTestSupport", dependencies: ["DeviceKit"]),
    .systemLibrary(name: "CLibMTP", pkgConfig: "libmtp", providers: [.brew(["libmtp"])]),
    .target(name: "MTPTransport", dependencies: ["DeviceKit", "CLibMTP"]),
    .target(
      name: "FerryAgentCore",
      dependencies: ["ADBTransport", "DeviceKit", "FerryIPC", "MTPTransport"],
      resources: [.process("Localizable.xcstrings")]),
    .target(name: "FerryIPC", dependencies: ["DeviceKit"]),
    .target(
      name: "FerryProviderCore", dependencies: ["DeviceKit", "FerryIPC"],
      resources: [.process("Localizable.xcstrings")]),
    .target(
      name: "FerrySyncCore", dependencies: ["DeviceKit", "FerryIPC", "FerryText"],
      resources: [.process("Localizable.xcstrings")]),
    .target(
      name: "FerryText", dependencies: ["DeviceKit", "FerryIPC"],
      resources: [.process("Localizable.xcstrings")]),
    .target(
      name: "FerryUI", dependencies: ["DeviceKit", "FerryIPC", "FerrySyncCore", "FerryText"],
      resources: [.process("Localizable.xcstrings"), .process("help.json")]),
    .executableTarget(
      name: "ferryctl",
      dependencies: [
        "DeviceKit", "MTPTransport",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]),
    .testTarget(name: "ADBTransportTests", dependencies: ["ADBTransport", "DeviceKit"]),
    .testTarget(
      name: "DeviceKitTests", dependencies: ["DeviceKit", "DeviceKitTestSupport"]),
    .testTarget(
      name: "MTPTransportTests",
      dependencies: ["MTPTransport", "DeviceKit", "DeviceKitTestSupport"]),
    .testTarget(
      name: "FerryAgentCoreTests",
      dependencies: [
        "ADBTransport", "FerryAgentCore", "FerryIPC", "DeviceKit", "DeviceKitTestSupport",
      ]),
    .testTarget(
      name: "FerryIPCTests", dependencies: ["FerryIPC", "DeviceKit", "DeviceKitTestSupport"]),
    .testTarget(
      name: "FerryProviderCoreTests",
      dependencies: ["FerryProviderCore", "FerryIPC", "DeviceKit", "DeviceKitTestSupport"]),
    .testTarget(
      name: "FerrySyncCoreTests",
      dependencies: [
        "FerrySyncCore", "FerryIPC", "FerryProviderCore", "FerryText", "DeviceKit",
        "DeviceKitTestSupport",
      ]),
    .testTarget(
      name: "FerryUITests",
      dependencies: ["FerryUI", "FerryIPC", "FerryText", "DeviceKit", "DeviceKitTestSupport"]),
  ],
  swiftLanguageModes: [.v6]
)
