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

1. **Changed `osc3_hz` for the `plus-color` and `plus-color-hexa` profiles from
   `20000000.0` (20 MHz) to `12000000.0` (12 MHz).** Found by timing a repeating idle
   animation (eye blinks) against a real Tamagotchi Plus Color side by side with this
   port: the real device blinked 10 times in 10 seconds and again ~30 times in a more
   careful 30-second count (1/sec, exactly matching its own real-time clock), while this
   port blinked roughly 50 times in the same 30 seconds with the original 20 MHz value —
   a ~5∶3 ratio, i.e. `20 MHz ÷ 12 MHz`. The displayed time-of-day clock itself was
   already correct (it's paced directly against wall-clock time, independent of this
   constant — see `EmulatorEngine.runLoop()` in the iOS app), but every cycle-timed
   animation (anything gated on a hardware timer counting raw CPU cycles rather than the
   RTC-second counter) was running proportionally faster than real hardware because of
   this one constant. `osc3_hz` feeds `periph.c`'s CMU/PLL math (`cmu_recalc`) as a linear
   scale factor on `mclk_hz`, the CPU/animation clock.
   
   **Correction to this entry's original claim**: this was first believed to uniformly
   affect *all* cycle-timed behavior including audio pitch, consistent with everything
   reading the same `mclk_hz`/`osc3_hz` value. Follow-up testing disproved that — see
   item 2 below and the new `tone_hz` field.

2. **Added a new `tone_hz` field to `DeviceProfile`** (declared in `include/emu.h`,
   populated for every device in `device.c`), read by `periph.c`'s `tone_update()`
   instead of `mclk_hz`/`osc3_hz`. Real Tamagotchi hardware's audio tone generation
   turned out to run off a clock independent of the CPU/animation one: after the
   `osc3_hz` correction above fixed animation speed (confirmed against real Plus Color
   hardware) sound pitch *also* dropped — but pitch had been *correct* ("sounded like a
   real Tamagotchi") before that change, at the original 20 MHz value. Since the core's
   prior code computed both animation timing and tone pitch from the identical `mhz`
   value, there was no way for 12 MHz to be simultaneously right for one and wrong for
   the other unless they're genuinely different clock domains being incorrectly modeled
   as one — confirmed further by the user independently loading the same Plus Color ROM
   onto a different piece of hardware (a community "Tamagotchi Paradise" multi-emulator
   device, likely built on a relative/descendant of this same core lineage), where
   animation speed was correct but audio pitch was *also* broken — the same symptom,
   on different hardware, pointing at a shared/upstream modeling gap rather than
   anything specific to this port. For every device except `plus-color`/
   `plus-color-hexa`, `tone_hz` is set equal to the existing `osc3_hz` (unchanged
   behavior — those devices were never reported as having a pitch problem; this project
   only owns real hardware to check Plus Color against, via a user comparison, so the
   other profiles' `tone_hz`/`osc3_hz` values remain just as unverified as they always
   were). For `plus-color`/`plus-color-hexa`, `tone_hz` is `20000000.0` — restoring the
   value that measurably sounded correct, kept independent of the now-corrected
   `osc3_hz` driving animation.

Nothing else in the core is modified. `main.c` and `panel.c` from the upstream project are
not part of this port at all — they are the SDL desktop front end, replaced here by Swift
code in the main app target.
