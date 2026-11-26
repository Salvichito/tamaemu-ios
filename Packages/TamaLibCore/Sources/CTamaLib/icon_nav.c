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
#define MAX_BACK  5
#define MAX_DARK  2
#define MAX_TOTAL 24

enum { NAV_IDLE, NAV_BACK, NAV_SELECT, NAV_OPEN };

static uint8_t s_phase = NAV_IDLE;
static uint8_t s_target, s_count;
static uint8_t s_held;           /* button being held, 0 = none */
static uint32_t s_until;         /* end of the hold, or of the wait after it */
static uint8_t s_before;         /* lights when the press started */
static bool s_waiting;           /* released, waiting for the lights to change */
static uint8_t s_back, s_dark, s_total;

void icon_nav_start(uint8_t target, uint8_t count, uint32_t now_us)
{
	if (count == 0 || target >= count || count > 8) { s_phase = NAV_IDLE; return; }
	s_target = target;
	s_count = count;
	s_phase = NAV_BACK;
	s_held = 0;
	s_waiting = false;
	s_until = now_us;
	s_back = s_dark = s_total = 0;
}

void icon_nav_cancel(void) { s_phase = NAV_IDLE; s_held = 0; }

bool icon_nav_active(void) { return s_phase != NAV_IDLE; }

/* Lowest menu light that's on, or -1. */
static int lit(uint8_t lights, uint8_t count)
{
	for (int i = 0; i < count; i++) if (lights & (1u << i)) return i;
	return -1;
}

static uint8_t hold(uint8_t button, uint32_t now_us, uint8_t lights)
{
	s_before = lights;
	if (++s_total > MAX_TOTAL) { icon_nav_cancel(); return 0; }
	s_held = button;
	s_until = now_us + HOLD_US;
	return button;
}

uint8_t icon_nav_tick(uint32_t now_us, uint8_t lights)
{
	if (s_phase == NAV_IDLE) return 0;
	uint8_t menu = (uint8_t)((1u << s_count) - 1);
	if (s_waiting && (lights & menu) != (s_before & menu)) {
		/* The press showed: settle briefly, then carry on. */
		s_waiting = false;
		s_until = now_us + SETTLE_US;
	}
	/* Signed difference: the core's microsecond clock wraps. */
	if ((int32_t)(now_us - s_until) < 0) return s_held;
	if (s_held) {
		s_held = 0;
		if (s_phase == NAV_OPEN) { s_phase = NAV_IDLE; return 0; } /* B went up: done */
		s_waiting = true;
		s_until = now_us + WAIT_US;
		return 0;
	}
	s_waiting = false;

	int cur = lit(lights, s_count);
	switch (s_phase) {
	case NAV_BACK:
		if (cur < 0) { s_phase = NAV_SELECT; return hold(0x1, now_us, lights); }
		if (++s_back > MAX_BACK) { icon_nav_cancel(); return 0; }
		return hold(0x4, now_us, lights);
	case NAV_SELECT:
		if (cur == s_target) { s_phase = NAV_OPEN; return hold(0x2, now_us, lights); }
		if (cur < 0) {
			if (++s_dark >= MAX_DARK) { icon_nav_cancel(); return 0; }
		} else {
			s_dark = 0;
		}
		return hold(0x1, now_us, lights);
	default:
		icon_nav_cancel();
		return 0;
	}
}
