// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SunoSorter",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "suno-sorter", targets: ["SunoSorter"])
    ],
    targets: [
        .executableTarget(
            name: "SunoSorter",
            path: "Sources/SunoSorter"
        )
    ]
)
