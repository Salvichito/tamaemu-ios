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

1. **`osc3_hz` lowered from the `20000000.0` datasheet value for `plus-color`
   and `plus-color-hexa`, currently `12000000.0`.** Idle blink-animation
   speed was measured against real Ps/Mix hardware (a careful stopwatch
   blink-count, not a guess) running about 1.7-1.8x too fast at the
   datasheet value. `osc3_hz` feeds the CMU/PLL math in `periph.c` that
   paces every CPU cycle, so it's the right lever for a uniform
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

   Melody *tempo* (not pitch) is not independent of `osc3_hz` the way pitch
   is, and neither are a few other things discovered since: minigame pacing
   (apple-catching felt slow) and part of at least one longer intro
   animation. First guess was that tempo shared the T16 hardware-timer
   mechanism (`periph_tick()`'s "Timer clocks use MCLK-derived
   prescalers"), so a `tone_hz`-style rescale of every T16 channel's
   prescaler divisor was tried. That was reverted: `periph_tick()`'s six
   T16 channels are shared by more than melody tempo (the 12MHz `osc3_hz`
   value was itself tuned against a real-hardware blink-count measurement,
   which strongly suggests idle/egg-phase blink animation also rides one or
   more of these same channels), so rescaling all six for tempo's sake sped
   up blinking past real hardware too — confirmed by a user-measured blink
   count (~20 blinks/10s on real hardware vs. 50+ and visibly uneven with
   the rescale applied).

   Temporary debug logging (added and removed in the same pass — see git
   history, not left in the tree) then traced an actual melody frame by
   frame: no T16 channel fires anywhere near the note-change rate. Tempo is
   instead a plain firmware busy-wait loop counting raw CPU cycles — the
   same clock as general CPU/animation throughput, with no separate timer
   involved at all (the gap between notes measured out to a fixed 2,457,600
   cycles, which is exactly 0.12288s at the real 20MHz clock — a classic
   round crystal-divisor number — confirming the loop's cycle count is
   fixed and its real-world duration is purely a function of `osc3_hz`).
   This means tempo, minigame pacing, and any other cycle-counted firmware
   delay are structurally tied to `osc3_hz` with no clean way to decouple
   them the way `tone_hz` decouples pitch (which sidesteps the issue
   entirely by recomputing frequency from register values instead of
   counting ticks) — short of detecting specific ROM address ranges and
   giving them their own cycle rate, which is fragile, firmware-version-
   specific reverse-engineering, not attempted here.

   Given that, `osc3_hz` is inherently a compromise, not a value that makes
   everything correct: blinking and tempo/minigame-pacing pull it in
   opposite directions (raising it from `12000000.0` toward the datasheet
   value helps the cycle-counted stuff but makes blinking faster than
   ideal, and vice versa), so there is no single number that's right for
   both. `14000000.0` was tried as a middle ground and reverted by direct
   side-by-side comparison against this value — it made blink/animation
   speed noticeably worse without melody tempo or minigame pacing feeling
   enough better to justify that. `12000000.0` — prioritizing blink-
   animation accuracy — is the preferred value until proven otherwise.

See `EmulatorEngine.swift`'s `runLoop()` in the iOS app for the cycle-ceiling
fix mentioned above.

Nothing else in the core is modified. `main.c` and `panel.c` from the upstream project are
not part of this port at all — they are the SDL desktop front end, replaced here by Swift
code in the main app target.
