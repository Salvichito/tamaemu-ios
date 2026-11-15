# Credits and core changes

The emulator core in `Sources/CTamaLib/` (`tamalib.c`, `cpu.c`, `hw.c`, and the headers
`tamalib.h`, `cpu.h`, `hw.h`, `hal.h` in `Sources/CTamaLib/include/`) is
**[TamaLib](https://github.com/jcrona/tamalib)** by **Jean-Christophe Rona**, used here
unmodified except as listed below, under its own licence, GNU GPL-2.0-or-later (see
`LICENSE`).

As required by the licence, every change made to the core for this port is listed here and
marked with an `// iOS port:` comment at the change site.

## `include/hal.h`

1. **`#include "../hal_types.h"` changed to `#include "hal_types.h"`.** Upstream expects its
   own `lib/` subfolder convention (headers one directory below the importing project's
   `hal_types.h`); this port keeps every TamaLib header in one flat directory instead.

## `include/cpu.h`

1. **`cpu_step`/`cpu_reset` renamed to `tlib_cpu_step`/`tlib_cpu_reset` via `#define`.** This
   app's other emulator core (`Packages/TamaCore`, a different, unrelated CPU for
   later-generation devices) also exports plain C functions named `cpu_step()`/`cpu_reset()`;
   both get statically linked into the same app binary, so the unqualified names collided at
   link time (`duplicate symbol`). The `#define` is placed before either is declared, so it
   retargets every use inside TamaLib itself — its own call sites, and `tamalib.h`'s
   `tamalib_reset()` macro — without editing a single call site.

## `cpu.c`

1. **`wait_for_cycles()` carries its division remainder (`ts_remainder`).** Upstream computes each
   step's duration as `(cycles * ts_freq)/(cpu_frequency * speed_ratio)` in integer math and
   discards the remainder every call. With microsecond timestamps and a 32768 Hz CPU that rounds
   a 152.59µs step down to 152µs, so the emulated chip — and the Tama's own clock — ran about
   0.39% fast (measured: ~5.5 minutes per day), live and during fast-forward catch-up alike. The
   remainder is now carried into the next call, which makes the long-run rate exact.

2. **`cpu_step()` looks opcodes up in a table (`op_lut`) instead of scanning `ops[]`.** Built once
   from the same `ops[]` entries with the same first-match rule, so decoding is unchanged; it only
   removes a linear search that dominated the cost of fast-forward catch-up.

3. **`cpu_step()` initialises `i` to `0xFF`.** Upstream leaves it unset on a step where the CPU is
   halted, then tests it to decide whether to take pending interrupts; when the leftover value
   happened to be 0 (PSET) or 58 (EI) a halted CPU never woke. Fix from Paramix Studio's V1Emu
   (see below).

4. **`cpu_kmask_fix` and the one-shot buzzer (`bz_shot`).** Upstream writes the K00-K03 interrupt
   mask into the serial slot, so key interrupts never arrive, and ignores the one-shot buzzer
   (0xF75 bit 3). The Digimon ROMs depend on both. `cpu_kmask_fix` is switched on for the Digimon
   only, so every Tamagotchi ROM keeps upstream's behaviour. Both from V1Emu.

## `hw.c` / `include/hw.h`

1. **Per-model LCD wiring (`hw_set_model`, `HW_MODEL_*`).** Upstream wires every ROM like a P1.
   Added: the Digimon's column and icon segments, Yasashii's direct segment-to-column layout, and
   the one-segment-per-icon layout of Umino, Genjintch and Tamaotch. From V1Emu.

2. **`hw_buzzer_shot()`**, and `hw_enable_buzzer()` now sounds the buzzer while either the normal
   output or a one-shot is on. From V1Emu.

## Changes taken from Paramix Studio's V1Emu

The changes marked "From V1Emu" above are ported from **V1Emu** by **mameise**, the modified copy
of TamaLib in [mameise/Paramix-Studio](https://github.com/mameise/Paramix-Studio) (`v1/src/core/`),
licensed GPL-3.0-or-later. They were re-applied by hand onto this port's copy of the core (keeping
upstream's `hw_*` names) rather than vendoring that copy whole. The ROM fingerprints the app uses
to recognise each dump (`DeviceCatalog.swift`) and the LCD orientation of the Digimon and Yasashii
(`hal_ios.c`) come from the same project. None of V1Emu's per-toy icon artwork is used.

Everything else in `Sources/CTamaLib/` — `hal_types.h`, `ios_hal.h`, `hal_ios.c` — is new code
written for this port (TamaLib's README calls this the required "abstraction layer between
TamaLIB and your OS or SDK"), not upstream source, and carries no GPL obligation beyond the
GPLv3 the rest of this repository is already under.
