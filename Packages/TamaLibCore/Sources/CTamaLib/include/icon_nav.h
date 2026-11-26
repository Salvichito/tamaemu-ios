#ifndef ICON_NAV_H
#define ICON_NAV_H

#include <stdbool.h>
#include <stdint.h>

/* Tap-an-icon shortcut for first-gen models whose A button steps a cursor
 * through menu lights 0..(count-1) and then "none" (P1/P2, Angel,
 * Morino, Umino, Genjintch, Tamaotch, Mothra measured headless
 * 2026-11-25; see TamaEmu's icon-probe notes). There's no way to
 * jump the toy's own program to a menu, so this presses the real buttons
 * for the user, fast, checking the lights after every press:
 *
 *   1. C until no menu light is on (backs out of any submenu: inside one,
 *      its icon stays lit; on the main screen C clears the cursor).
 *   2. A until the target light is the one lit.
 *   3. B to open it.
 *
 * A dropped or doubled press just changes what the next look at the
 * lights sees, so it self-corrects; it gives up (and lets go of every
 * button) if the lights don't behave like a menu -- egg, clock setting,
 * asleep, mid-game.
 *
 * Pure state machine, no core calls: the caller feeds it the core's own
 * clock and current lights once per stepping pass and forwards the
 * returned mask (bit0=A bit1=B bit2=C) to the buttons. */

/* Starts heading for `target` (0..count-1), replacing any run in
 * progress. `count` is how many lights A cycles through (7 on the P1). */
void icon_nav_start(uint8_t target, uint8_t count, uint32_t now_us);

/* Stops at once; the next icon_nav_tick() returns 0. */
void icon_nav_cancel(void);

bool icon_nav_active(void);

/* `lights` = bit i set while light i is on. Returns the buttons to hold
 * right now (0 once finished or given up). */
uint8_t icon_nav_tick(uint32_t now_us, uint8_t lights);

#endif
