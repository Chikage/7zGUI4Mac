// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SevenZipMac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SevenZipMac", targets: ["SevenZipMac"])],
    targets: [
        .target(name: "ArchiveCore"),
        .executableTarget(name: "SevenZipMac", dependencies: ["ArchiveCore"]),
        .testTarget(name: "ArchiveCoreTests", dependencies: ["ArchiveCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "SevenZipMacTests", dependencies: ["SevenZipMac", "ArchiveCore"]),
    ],
    swiftLanguageModes: [.v6]
)
