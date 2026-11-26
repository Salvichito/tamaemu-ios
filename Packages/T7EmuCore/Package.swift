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
                // Same core switches upstream's own Paradise build uses
                // (t7/src/app/build.sh), limited to the ones that are about
                // timing and speed, not the Paradise hardware:
                // - T7_VIDEO_CYCLES: video IRQ at 60 Hz of emulated time no
                //   matter how the host slices the stepping. Without it the
                //   core assumes 20 calls/s and fired 180 video IRQs/s here.
                // - T7_FASTRUN: the register-caching interpreter (t7_run.inc),
                //   same results instruction by instruction; ~1.6x faster.
                // - T7_IDLE: skips the main loop's idle wait in one go
                //   (bit-identical); ~7x faster catch-up. Upstream's check
                //   only knew the Tama-Go's copy of the loop; this port's
                //   (see CREDITS.md) finds Friends' too, ~8x faster there.
                // Checked headless against the plain interpreter: same screen
                // every emulated minute over 2 h of random play, both ROMs.
                .define("T7_VIDEO_CYCLES"),
                .define("T7_FASTRUN"),
                .define("T7_IDLE"),
                // - T7_LINK: takes each infrared packet the Tama-Go sends
                //   (t7_ir_tx_take), for Connect Nearby. Only acts when the
                //   game switches its infrared LED on.
                .define("T7_LINK"),
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
