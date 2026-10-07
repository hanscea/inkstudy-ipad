// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "InkStudyCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "InkStudyCore", targets: ["InkStudyCore"]), .executable(name: "PigmentBenchmark", targets: ["PigmentBenchmark"])],
    targets: [
        .target(name: "InkStudyCore", resources: [.process("Resources")], linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "InkStudyCoreTests", dependencies: ["InkStudyCore"]),
        .executableTarget(name: "PigmentBenchmark", dependencies: ["InkStudyCore"], path: "Benchmarks")
    ]
)
