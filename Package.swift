// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "Ferry",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "DeviceKit", targets: ["DeviceKit"]),
    .library(name: "DeviceKitTestSupport", targets: ["DeviceKitTestSupport"]),
  ],
  targets: [
    .target(name: "DeviceKit"),
    .target(name: "DeviceKitTestSupport", dependencies: ["DeviceKit"]),
    .systemLibrary(name: "CLibMTP", pkgConfig: "libmtp", providers: [.brew(["libmtp"])]),
    .target(name: "MTPTransport", dependencies: ["DeviceKit", "CLibMTP"]),
    .testTarget(
      name: "DeviceKitTests", dependencies: ["DeviceKit", "DeviceKitTestSupport"]),
    .testTarget(name: "MTPTransportTests", dependencies: ["MTPTransport", "DeviceKit"]),
  ],
  swiftLanguageModes: [.v6]
)
