// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "T18EmuCore",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "T18EmuCore", targets: ["CT18Emu"])
    ],
    targets: [
        .target(
            name: "CT18Emu",
            cSettings: [
                // Core switches from upstream's own build (t18/src/app/build.sh),
                // limited to ones about the emulated hardware, not the Paradise:
                // - T18_RADIO: the Bluetooth module answers like the real one
                //   with no phone attached. Without it the camera (item box,
                //   Special) stays at READY? and takes no key.
                // - T18_IDLE_MEMO: skips repeated idle rounds of the main loop
                //   it has already seen (same results, instruction by instruction).
                // - T18_BL_STRICT: the screen light only comes from the timer's
                //   PWM output, so the minute wake-ups don't flash the screen.
                .define("T18_RADIO"),
                .define("T18_IDLE_MEMO"),
                .define("T18_BL_STRICT"),
                .unsafeFlags(["-O3", "-fno-strict-aliasing", "-Wno-macro-redefined"])
            ]
        ),
        .testTarget(
            name: "CT18EmuTests",
            dependencies: ["CT18Emu"]
        )
    ],
    cLanguageStandard: .c11
)
