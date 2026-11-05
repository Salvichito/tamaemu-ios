// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TamaLibCore",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "TamaLibCore", targets: ["CTamaLib"])
    ],
    targets: [
        .target(
            name: "CTamaLib",
            cSettings: [
                .unsafeFlags(["-O3", "-fno-strict-aliasing"])
            ]
        ),
        .testTarget(
            name: "CTamaLibTests",
            dependencies: ["CTamaLib"]
        )
    ],
    cLanguageStandard: .c11
)
