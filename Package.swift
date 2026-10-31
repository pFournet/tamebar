// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "Tamebar",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "Tamebar", targets: ["Tamebar"])
  ],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.2")
  ],
  targets: [
    .executableTarget(
      name: "Tamebar",
      dependencies: [.product(name: "Sparkle", package: "Sparkle")]),
    .testTarget(name: "TamebarTests", dependencies: ["Tamebar"]),
  ]
)
