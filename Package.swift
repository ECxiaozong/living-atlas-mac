// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "LivingAtlasMac",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "LivingAtlas", targets: ["LivingAtlas"]),
    .executable(name: "atlas", targets: ["AtlasCLI"]),
  ],
  dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.12.0")],
  targets: [
    .systemLibrary(name: "CAtlasArchive"),
    .target(name: "AtlasIPC"),
    .executableTarget(name: "AtlasCLI", dependencies: ["AtlasIPC"]),
    .target(
      name: "AtlasCore",
      dependencies: ["AtlasIPC", "CAtlasArchive", .product(name: "GRDB", package: "GRDB.swift")],
      resources: [.copy("Resources/schema.sql"), .copy("Resources/ChineseSearch")]),
    .executableTarget(
      name: "LivingAtlas", dependencies: ["AtlasCore", "AtlasIPC"],
      resources: [.copy("Art"), .copy("AnswerRendering"), .copy("Fonts")]),
    .testTarget(name: "AtlasCoreTests", dependencies: ["AtlasCore"]),
  ], swiftLanguageModes: [.v5]
)
