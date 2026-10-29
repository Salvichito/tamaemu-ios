# Credits and core changes

The emulator core in `Sources/CTama/` (`cpu.c`, `mem.c`, `lcd.c`, `periph.c`, `device.c`,
`state.c`, `savepath.c`, `link.c`, `pn512.c`, `nfcpeer.c`, `disasm.c`, `tamasave.c`, and the
headers in `Sources/CTama/include/`) was written by
**[maragotchi](https://github.com/maragotchi/tamaemu)** and is used here under the same
licence, GNU GPL-3.0 (see `LICENSE`).

As required by the licence, every change made to the core for this iOS port is listed here
and marked with a `// iOS port:` comment at the change site.

## `link.c`

1. **Added `#include <stdlib.h>` and `#include <time.h>`.** `clock_gettime` and `atoi` need
   them under strict C99/C11 (implicit function declarations are now a hard error). The
   upstream desktop build gets these declared implicitly via some other transitively
   included header; this port makes the dependency explicit instead. This is the same fix
   already documented by the Android port
   ([TamaEmu_Android/CORE-CHANGES.md](https://github.com/mameise/TamaEmu_Android/blob/main/CORE-CHANGES.md)),
   applied here independently after hitting the identical build error.

`device.c` and `include/emu.h` were briefly modified (a changed `osc3_hz` for
`plus-color`/`plus-color-hexa`, plus a new `tone_hz` field) while chasing an animation-speed
report, on the mistaken belief that the *core's own data* was wrong. That was reverted once
testing the Android port's own copy of this exact core, unmodified, on real Android hardware
showed speed, pitch, *and* melody tempo all correct — proving `osc3_hz = 20000000.0` was
right all along, and the real bug was specific to this port's emulator loop, not the shared
core. See `EmulatorEngine.swift`'s `runLoop()` in the iOS app for the actual fix and the full
story. `device.c`, `periph.c`, and `include/emu.h` are, as of that revert, unmodified from
upstream again.

Nothing else in the core is modified. `main.c` and `panel.c` from the upstream project are
not part of this port at all — they are the SDL desktop front end, replaced here by Swift
code in the main app target.
