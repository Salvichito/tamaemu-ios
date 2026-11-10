// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "T7EmuCore",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "T7EmuCore", targets: ["CT7Emu"])
    ],
    targets: [
        .target(
            name: "CT7Emu",
            cSettings: [
                .unsafeFlags(["-O3", "-fno-strict-aliasing"])
            ]
        ),
        .testTarget(
            name: "CT7EmuTests",
            dependencies: ["CT7Emu"]
        )
    ],
    cLanguageStandard: .c11
)
