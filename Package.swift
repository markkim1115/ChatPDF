// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChatPDF",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ChatPDF", targets: ["PDFReader"])],
    targets: [
        .target(name: "PDFReaderCore"),
        .executableTarget(name: "PDFReader", dependencies: ["PDFReaderCore"]),
        .testTarget(name: "PDFReaderCoreTests", dependencies: ["PDFReaderCore"])
    ],
    swiftLanguageModes: [.v5]
)
