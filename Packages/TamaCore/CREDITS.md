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

## `device.c`

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
   this one constant. `osc3_hz` only ever appears as a linear scale factor feeding
   `periph.c`'s CMU/PLL math (`cmu_recalc`), so a uniform, device-wide speed error from a
   single wrong crystal-frequency constant was consistent with every symptom observed:
   internally self-consistent timing (buttons, sound, boot sequence all "worked"), just
   uniformly sped up. Not yet re-verified against the desktop (`tamaemu`) or Android
   (`TamaEmu_Android`) builds, which carry the same `20000000.0` value unchanged — this is
   likely an upstream data error inherited by all three, not something introduced by
   either port, but that comparison hasn't been done.

Nothing else in the core is modified. `main.c` and `panel.c` from the upstream project are
not part of this port at all — they are the SDL desktop front end, replaced here by Swift
code in the main app target.
