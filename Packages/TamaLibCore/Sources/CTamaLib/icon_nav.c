#include "icon_nav.h"

/* Press length, in the core's own (emulated) time. After letting go, it
 * waits for the lights to change -- the P1 takes a few hundred ms to show
 * a press (measured headless 2026-11-25), and pressing again before then
 * gets presses dropped -- but at most WAIT_US, then looks anyway (a press
 * that changed nothing, e.g. C on a cleared screen). SETTLE_US after a
 * change before the next press. */
#define HOLD_US   160000u /* Tamaotch drops shorter presses */
#define WAIT_US   700000u
#define SETTLE_US 60000u
/* Give-up limits: C presses while backing out, A presses that light
 * nothing in a row (clock setting / egg / asleep: stop before A changes
 * anything else), and presses in all. */
#define MAX_BACK  10
#define MAX_DARK  2
#define MAX_TOTAL 30

enum { NAV_IDLE, NAV_BACK, NAV_SELECT, NAV_OPEN };

void icon_nav_start(icon_nav_t *n, uint8_t target, uint8_t count, uint32_t now_us)
{
	*n = (icon_nav_t){0};
	if (count == 0 || target >= count || count > 16) return;
	n->target = target;
	n->count = count;
	n->phase = NAV_BACK;
	n->until = now_us;
}

void icon_nav_cancel(icon_nav_t *n) { n->phase = NAV_IDLE; n->held = 0; }

bool icon_nav_active(const icon_nav_t *n) { return n->phase != NAV_IDLE; }

/* Lowest menu light that's on, or -1. */
static int lit(uint16_t lights, uint8_t count)
{
	for (int i = 0; i < count; i++) if (lights & (1u << i)) return i;
	return -1;
}

static uint8_t hold(icon_nav_t *n, uint8_t button, uint32_t now_us, uint16_t lights)
{
	n->before = lights;
	if (++n->total > MAX_TOTAL) { icon_nav_cancel(n); return 0; }
	n->held = button;
	n->until = now_us + HOLD_US;
	return button;
}

uint8_t icon_nav_tick(icon_nav_t *n, uint32_t now_us, uint16_t lights)
{
	if (n->phase == NAV_IDLE) return 0;
	uint16_t menu = (uint16_t)((1u << n->count) - 1);
	if (n->waiting && (lights & menu) != (n->before & menu)) {
		/* The press showed: settle briefly, then carry on. */
		n->waiting = false;
		n->until = now_us + SETTLE_US;
	}
	/* Signed difference: the core's microsecond clock wraps. */
	if ((int32_t)(now_us - n->until) < 0) return n->held;
	if (n->held) {
		n->held = 0;
		if (n->phase == NAV_OPEN) { n->phase = NAV_IDLE; return 0; } /* B went up: done */
		n->waiting = true;
		n->until = now_us + WAIT_US;
		return 0;
	}
	n->waiting = false;

	int cur = lit(lights, n->count);
	switch (n->phase) {
	case NAV_BACK:
		if (cur < 0) { n->phase = NAV_SELECT; return hold(n, 0x1, now_us, lights); }
		if (++n->back > MAX_BACK) { icon_nav_cancel(n); return 0; }
		return hold(n, 0x4, now_us, lights);
	case NAV_SELECT:
		if (n->target == cur) { n->phase = NAV_OPEN; return hold(n, 0x2, now_us, lights); }
		if (cur < 0) {
			if (++n->dark >= MAX_DARK) { icon_nav_cancel(n); return 0; }
		} else {
			n->dark = 0;
		}
		return hold(n, 0x1, now_us, lights);
	default:
		icon_nav_cancel(n);
		return 0;
	}
}
