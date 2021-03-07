// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "FFmpeg",
    products: [
        .library(name: "FFmpeg", targets: ["FFmpeg"]),
    ],
    dependencies: [
    ],
    targets: [
        .binaryTarget(
            name: "FFmpeg",
            path: "FFmpeg.xcframework"
        )
    ]
)
