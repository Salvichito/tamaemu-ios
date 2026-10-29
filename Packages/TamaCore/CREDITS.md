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

## `device.c` and `include/emu.h`

1. **`osc3_hz` lowered from `20000000.0` to `12000000.0` for `plus-color` and
   `plus-color-hexa`.** Idle blink-animation speed was measured against real
   Ps/Mix hardware (a careful stopwatch blink-count, not a guess) running
   about 1.7-1.8x too fast. `osc3_hz` feeds the CMU/PLL math in `periph.c`
   that paces every CPU cycle, so it's the right lever for a uniform
   animation-speed scale factor.

   This was first believed to be a port-side bug (a missing cycle ceiling in
   the iOS app's `EmulatorEngine.swift` `runLoop()`, matching a "notbremse"
   guard Android's own port has) and the constant was briefly reverted to
   `20000000.0` while that fix was tried instead. The cycle-ceiling fix is
   real and worth keeping (it prevents a genuine edge case — a firmware
   sleep/wake clock-rate transition making a handful of cycles masquerade as
   many seconds of simulated time — see the comments at that fix site) but
   testing showed it is not sufficient on its own: Android's unmodified
   reference core, with that same guard already in place, still runs idle
   animation measurably too fast on real Android hardware (most noticeable
   in the arcade minigames). That rules "the datasheet value is simply
   correct" back out — `12000000.0` is restored.

2. **Added a `tone_hz` field to `DeviceProfile`** (zero for every device
   except `plus-color`/`plus-color-hexa`, where it's `20000000.0`),
   consumed in `periph.c`'s `tone_update()` and T2-restart audio-pitch
   calculation in place of `osc3_hz`/`mclk_hz` when set. Audio pitch and the
   melody-timer interrupt read the exact same CMU-derived clock as CPU/
   animation timing, so lowering `osc3_hz` alone dropped pitch too — and it
   had been correct at `20000000.0`. `tone_hz` decouples it.

   Melody *tempo* (not pitch) is driven by the same T16 hardware-timer
   mechanism as general CPU cycle throughput (`periph_tick()`'s "Timer
   clocks use MCLK-derived prescalers"), which is tied to `osc3_hz`, not
   `tone_hz` — so tempo is not fully independent of the animation-speed
   constant the way pitch is. In practice this has been reported as an
   acceptable trade (a short melody's tempo is far less perceptually
   sensitive to a clock-rate shift than many seconds of continuously
   compounding animation drift), but it's a known, structural limitation of
   this fix, not a coincidence — a fully independent tempo clock would need
   splitting the CPU's single shared cycle counter into separate animation
   and timer-interrupt streams, which is a materially bigger change than
   this one constant.

See `EmulatorEngine.swift`'s `runLoop()` in the iOS app for the cycle-ceiling
fix mentioned above.

Nothing else in the core is modified. `main.c` and `panel.c` from the upstream project are
not part of this port at all — they are the SDL desktop front end, replaced here by Swift
code in the main app target.
