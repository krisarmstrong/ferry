// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "Ferry",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "DeviceKit", targets: ["DeviceKit"])
  ],
  targets: [
    .target(name: "DeviceKit"),
    .testTarget(name: "DeviceKitTests", dependencies: ["DeviceKit"]),
  ],
  swiftLanguageModes: [.v6]
)
