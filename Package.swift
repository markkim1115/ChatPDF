// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PDFReader",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PDFReader", targets: ["PDFReader"])],
    targets: [
        .target(name: "PDFReaderCore"),
        .executableTarget(name: "PDFReader", dependencies: ["PDFReaderCore"]),
        .testTarget(name: "PDFReaderCoreTests", dependencies: ["PDFReaderCore"])
    ],
    swiftLanguageModes: [.v5]
)
