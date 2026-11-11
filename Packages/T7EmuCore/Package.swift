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
                .unsafeFlags(["-O3", "-fno-strict-aliasing"]),
                // t7_cpu.c's __attribute__((hot, optimize("O2"))) is a GCC-only
                // attribute combination; Clang understands `hot` but not
                // `optimize`, so it ignores the latter and warns. Vendored
                // code, not modified for that reason alone (see CREDITS.md).
                .unsafeFlags(["-Wno-unknown-attributes"])
            ]
        ),
        .testTarget(
            name: "CT7EmuTests",
            dependencies: ["CT7Emu"]
        )
    ],
    cLanguageStandard: .c11
)
