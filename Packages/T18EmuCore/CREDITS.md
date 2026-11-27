# Credits and core changes

The emulator core in `Sources/CT18Emu/` (`t18cpu.c`, `t18soc.c`, `t18hle.inc`, and the
headers `t18cpu.h`, `t18soc.h` in `Sources/CT18Emu/include/`) is **T18Emu** by
**mameise**, vendored from [mameise/Paramix-Studio](https://github.com/mameise/Paramix-Studio)'s
`t18/src/core/` (commit b114ca4, 2026-11-20), under that repository's license, GNU
GPL-3.0-or-later (see `LICENSE`). It emulates the Tamagotchi Meets / Tamagotchi On
(TG18 firmware: ARM7TDMI with the GeneralPlus GPEL3101A peripherals).

No firmware is part of this repository: the user imports their own 8 MB dump.

Not vendored, and not needed by this port:

- `t18jit.c` and `t2enc.h` — a translator from ARM/Thumb to Thumb-2 for the Paradise's
  own Cortex-M3. An iPhone runs the plain interpreter far faster than real time.
- `t18/src/app` — the Paradise host (screen, keys, flash layout, settings menu).
- `t18/host/ref.c` — upstream's PC reference host. `ios_t18_compat.c` follows its setup
  (flash and SRAM buffers, the flash block map) but is this port's own code.

As required by the license, every change made to the vendored core files is listed here
and marked with an `// iOS port:` (or `/* iOS port: */`) comment at the change site:

1. `t18hle.c` is renamed `t18hle.inc`, and the one `#include` of it at the end of
   `t18cpu.c` follows the rename. Upstream never compiles that file on its own (it is
   only textually included), but SwiftPM compiles every `.c` file in a target.

Added for this port (not upstream source):

- `ios_t18_compat.c`, `include/ios_t18.h` — the platform side the core expects (the
  8 MB guest flash with a record of which 4 KB sectors the game wrote, the 128 KB guest
  SRAM), the Param-block search (same as Paramix Studio's `t18Param`), save/load of the
  session and of the game's own flash save, and a 1 ms sound timeline rendered as a
  square wave.
