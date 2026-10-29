// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TamaCore",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "TamaCore", targets: ["TamaCore"])
    ],
    targets: [
        .target(
            name: "CTama",
            cSettings: [
                .unsafeFlags(["-O3", "-fno-strict-aliasing"])
            ]
        ),
        .target(
            name: "TamaCore",
            dependencies: ["CTama"]
        ),
        .testTarget(
            name: "TamaCoreTests",
            dependencies: ["TamaCore"]
        )
    ],
    cLanguageStandard: .c11
)
