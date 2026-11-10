# Credits and core changes

The emulator core in `Sources/CT7Emu/` (`t7.c`, `t7_cpu.c`, `t7_memory.c`, `t7_eeprom.c`,
`t7_sound.c`, `t7_run.inc`, and the headers `t7.h`, `t7_internal.h`, `t7_eeprom.h`,
`t7_sound.h`, `pebble_compat.h` in `Sources/CT7Emu/include/`) is **T7Emu** by
**mameise**, vendored unmodified from
[mameise/Paramix-Studio](https://github.com/mameise/Paramix-Studio)'s `t7/src/core/`,
under that repository's license, GNU GPL-3.0-or-later (see `LICENSE`). T7Emu's own
header comments identify it as a C port of **[tamago](https://github.com/asterick/tamago)**
by **asterick** (a JavaScript Tama-Go/Tamagotchi Friends emulator, BSD-licensed per that
repo's `package.json`); T7Emu's copyright and license are the applicable ones for the
code vendored here, since nothing from the JS original was copied directly.

Not vendored, and not needed by this port:

- `t7_jit.c`/`t7_jit.h` — a Thumb-2 JIT translator specific to the Paradise's own ARM
  Cortex-M3 (not portable, and unnecessary on an iPhone's CPU for a 4 MHz 6502-class
  core). `t7.c`'s plain interpreter path (`t7_cpu_step`, used when `T7_FASTRUN` is
  undefined) is what this port uses; `t7_run.inc` is vendored only because `t7_cpu.c`
  textually includes it, but its entire contents are themselves behind
  `#ifdef T7_FASTRUN`, which this port never defines, so none of it is actually compiled.
- `figure_data.c` and the `t7/src/app` Paradise host layer — figure-accessory ROM blobs
  and Paradise-hardware-specific code (screen/menu/UART), out of scope for this port.
  `t7_memory.c` declares two externs for figure-ROM access
  (`figure_rom_ptr`/`figure_rom_length`); this port stubs both to report "no figure
  plugged in" (see `ios_t7_compat.c`) rather than vendoring that file.

As required by the license, every change made to the vendored core files for this port
would be listed here and marked with an `// iOS port:` comment at the change site — there
are none; every file under `Sources/CT7Emu/` other than `ios_t7_compat.c` and the new
header `include/ios_t7.h` is byte-for-byte what was vendored, including
`include/pebble_compat.h`, which turned out to already be a pure declarations-only
header (no Pebble-specific code in it) describing exactly the small logging/resource/
persist surface the core needs from its host -- the same seam T7Emu's own upstream
already swaps per target (a Pebble variant, an ESP32-C6 variant, and the Paradise's own
ARM variant all exist upstream). `ios_t7_compat.c` is this port's own implementation of
that surface, backed by ordinary POSIX files instead of Pebble's `APP_LOG`/resource/
persist APIs, plus the public `ios_t7_*` entry points this port adds on top of t7.h,
declared in `include/ios_t7.h` -- both new code written for this port, not upstream
source, carrying no GPL obligation beyond the GPLv3 the rest of this repository is
already under.
