// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CodexQuotaMenu",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexQuotaMenu", targets: ["CodexQuotaMenu"])
    ],
    targets: [
        .executableTarget(
            name: "CodexQuotaMenu",
            path: "Sources/CodexQuotaMenu"
        ),
        .testTarget(
            name: "CodexQuotaMenuTests",
            dependencies: ["CodexQuotaMenu"],
            path: "Tests/CodexQuotaMenuTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
