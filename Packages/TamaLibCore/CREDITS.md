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

Everything else in `Sources/CTamaLib/` — `hal_types.h`, `ios_hal.h`, `hal_ios.c` — is new code
written for this port (TamaLib's README calls this the required "abstraction layer between
TamaLIB and your OS or SDK"), not upstream source, and carries no GPL obligation beyond the
GPLv3 the rest of this repository is already under.
