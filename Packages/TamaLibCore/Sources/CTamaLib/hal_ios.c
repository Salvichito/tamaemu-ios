/* iOS port: TamaLib's required hal_t implementation for this port (see
 * hal.h's own doc comment on what this layer is), plus the small public C
 * API (ios_hal.h) the Swift side calls. Not upstream source. See
 * CREDITS.md.
 *
 * This first pass is a headless smoke test's HAL: it stores LCD/icon/tone
 * state in plain static buffers and logs errors to stderr. It has no
 * button/save wiring yet -- see the integration-research memory for the
 * staged plan.
 */
#include "ios_hal.h"
#include "tamalib.h"
#include "hal.h"
#include "hw.h"

#include <os/lock.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static bool s_lcd[IOS_HAL_LCD_HEIGHT][IOS_HAL_LCD_WIDTH];
static bool s_icons[IOS_HAL_ICON_COUNT];
static bool s_tone_on;
static uint32_t s_tone_freq_dhz;

static uint64_t s_step_count;
static uint64_t s_screen_update_count;
static uint64_t s_error_count;

static struct timespec s_start_ts;

/* iOS port: TamaLib has no unpaced "catch up" mode of its own -- every
 * tamalib_step() call paces itself to the real chip's actual speed via
 * sleep_until(), which is right for live play but means fast-forwarding
 * (background catch-up, or just testing past a long boot sequence) would
 * otherwise cost real wall-clock minutes per simulated minute. Faking the
 * clock here instead of actually sleeping gives the same effect as the
 * other core's cpu_step_catchup(), without touching TamaLib itself: the
 * firmware still sees a correctly-advancing clock, just one that jumps
 * straight to each requested wake time instead of waiting for it. */
static bool s_fast_forward;
static timestamp_t s_ff_now;

/* iOS port: s_start_ts/s_ff_now/s_fast_forward are read on the emulator's
 * own stepping thread (every single step, via s_get_timestamp/
 * s_sleep_until) and written from whatever thread calls
 * ios_hal_set_fast_forward -- a UI button, typically. Without a lock that's
 * a data race on a multi-field struct (s_start_ts): a step reading it
 * mid-write can see a torn, inconsistent combination of its two fields,
 * which the signed/unsigned arithmetic below turns into a wildly wrong
 * "now" -- in practice, a sleep_until() deadline so far in the future that
 * the engine looks permanently frozen, surviving even toggling fast-forward
 * back on, since the thread is already blocked inside that one nanosleep()
 * and won't re-check anything until it returns on its own. Found exactly
 * this way: toggling the button while live. */
static os_unfair_lock s_clock_lock = OS_UNFAIR_LOCK_INIT;

static timestamp_t s_get_timestamp(void)
{
	os_unfair_lock_lock(&s_clock_lock);
	bool ff = s_fast_forward;
	timestamp_t ff_now = s_ff_now;
	struct timespec start = s_start_ts;
	os_unfair_lock_unlock(&s_clock_lock);

	if (ff) {
		return ff_now;
	}
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	/* Signed throughout, clamped to 0 -- a torn read elsewhere should be
	 * impossible now that every access is lock-guarded, but a negative
	 * "elapsed" is cheap to make harmless anyway rather than relying on
	 * that alone. */
	int64_t us = (int64_t)(now.tv_sec - start.tv_sec) * 1000000LL
		+ (int64_t)(now.tv_nsec - start.tv_nsec) / 1000LL;
	if (us < 0) {
		us = 0;
	}
	return (timestamp_t)us;
}

static void s_sleep_until(timestamp_t ts)
{
	os_unfair_lock_lock(&s_clock_lock);
	bool ff = s_fast_forward;
	if (ff) {
		s_ff_now = ts;
	}
	os_unfair_lock_unlock(&s_clock_lock);
	if (ff) {
		return;
	}

	/* Signed delta so an already-past deadline (ts behind now) comes out
	 * negative rather than wrapping to a huge unsigned gap. */
	int64_t delta_us = (int64_t)ts - (int64_t)s_get_timestamp();
	if (delta_us > 0) {
		struct timespec req;
		req.tv_sec = delta_us / 1000000;
		req.tv_nsec = (delta_us % 1000000) * 1000;
		nanosleep(&req, NULL);
	}
}

void ios_hal_set_fast_forward(bool enabled)
{
	os_unfair_lock_lock(&s_clock_lock);
	if (enabled == s_fast_forward) {
		os_unfair_lock_unlock(&s_clock_lock);
		return;
	}
	if (enabled) {
		/* Enter fast-forward from whatever real time it is now (inlined
		 * rather than calling s_get_timestamp(), which would re-enter
		 * this same non-recursive lock). */
		struct timespec now;
		clock_gettime(CLOCK_MONOTONIC, &now);
		int64_t us = (int64_t)(now.tv_sec - s_start_ts.tv_sec) * 1000000LL
			+ (int64_t)(now.tv_nsec - s_start_ts.tv_nsec) / 1000LL;
		s_ff_now = (timestamp_t)(us < 0 ? 0 : us);
	} else {
		/* Leaving fast-forward: rebase the real clock so it continues
		 * from s_ff_now instead of jumping back to true elapsed time. */
		struct timespec now;
		clock_gettime(CLOCK_MONOTONIC, &now);
		uint64_t back_us = s_ff_now;
		s_start_ts = now;
		s_start_ts.tv_sec -= back_us / 1000000;
		int64_t rem_ns = (int64_t)(back_us % 1000000) * 1000;
		if (rem_ns > s_start_ts.tv_nsec) {
			s_start_ts.tv_sec -= 1;
			s_start_ts.tv_nsec += 1000000000;
		}
		s_start_ts.tv_nsec -= rem_ns;
	}
	s_fast_forward = enabled;
	os_unfair_lock_unlock(&s_clock_lock);
}

static void *s_malloc(u32_t size)
{
	return malloc(size);
}

static void s_free(void *ptr)
{
	free(ptr);
}

static void s_halt(void)
{
	/* Firmware entered its own halt/sleep; nothing to do headlessly. */
}

static bool_t s_is_log_enabled(log_level_t level)
{
	return level == LOG_ERROR;
}

static void s_log(log_level_t level, char *buff, ...)
{
	/* iOS port: cpu.c calls log() unconditionally on every memory access
	 * (LOG_MEMORY/LOG_CPU/LOG_INT) -- it never checks is_log_enabled()
	 * itself for those, only for the one disassembly-trace call site.
	 * Filtering here, not just counting, is what actually keeps a live
	 * run from formatting and writing a line per RAM/display access. */
	if (level == LOG_ERROR) {
		s_error_count++;
	}
	if (!s_is_log_enabled(level)) {
		return;
	}
	va_list args;
	va_start(args, buff);
	vfprintf(stderr, buff, args);
	va_end(args);
}

static void s_update_screen(void)
{
	s_screen_update_count++;
}

static void s_set_lcd_matrix(u8_t x, u8_t y, bool_t val)
{
	if (x < IOS_HAL_LCD_WIDTH && y < IOS_HAL_LCD_HEIGHT) {
		s_lcd[y][x] = val ? true : false;
	}
}

static void s_set_lcd_icon(u8_t icon, bool_t val)
{
	if (icon < IOS_HAL_ICON_COUNT) {
		s_icons[icon] = val ? true : false;
	}
}

static void s_set_frequency(u32_t freq)
{
	s_tone_freq_dhz = freq;
}

static void s_play_frequency(bool_t en)
{
	s_tone_on = en ? true : false;
}

static int s_handler(void)
{
	/* Only tamalib_mainloop() calls this; this port drives ios_hal_step()
	 * itself instead, so it's never actually invoked -- hal.h still
	 * requires every pointer to be non-NULL. */
	return 0;
}

static hal_t s_hal = {
	.malloc = s_malloc,
	.free = s_free,
	.halt = s_halt,
	.is_log_enabled = s_is_log_enabled,
	.log = s_log,
	.sleep_until = s_sleep_until,
	.get_timestamp = s_get_timestamp,
	.update_screen = s_update_screen,
	.set_lcd_matrix = s_set_lcd_matrix,
	.set_lcd_icon = s_set_lcd_icon,
	.set_frequency = s_set_frequency,
	.play_frequency = s_play_frequency,
	.handler = s_handler,
};

int ios_hal_start(const uint16_t *program, uint32_t program_words)
{
	/* TamaLib's own program buffer spans a fixed MEMORY_SIZE (4096 words);
	 * sizing/padding it is the caller's job, same as every upstream front
	 * end. Kept as a parameter here for a future bounds check once real
	 * ROM loading lands. */
	(void)program_words;

	memset(s_lcd, 0, sizeof(s_lcd));
	memset(s_icons, 0, sizeof(s_icons));
	s_tone_on = false;
	s_tone_freq_dhz = 0;
	s_step_count = 0;
	s_screen_update_count = 0;
	s_error_count = 0;
	s_fast_forward = false;
	s_ff_now = 0;
	clock_gettime(CLOCK_MONOTONIC, &s_start_ts);

	tamalib_register_hal(&s_hal);
	/* 0 = success, matching tamalib_init's own convention (ORs cpu_init's
	 * and hw_init's results, both 0 on success). */
	return tamalib_init((const u12_t *)program, NULL, 1000000);
}

void ios_hal_step(void)
{
	tamalib_step();
	s_step_count++;
}

void ios_hal_stop(void)
{
	tamalib_release();
}

bool ios_hal_get_pixel(uint8_t x, uint8_t y)
{
	if (x >= IOS_HAL_LCD_WIDTH || y >= IOS_HAL_LCD_HEIGHT) {
		return false;
	}
	return s_lcd[y][x];
}

void ios_hal_get_frame(uint8_t *out_bits_64, uint8_t *out_icons)
{
	memset(out_bits_64, 0, 64);
	for (uint8_t y = 0; y < IOS_HAL_LCD_HEIGHT; y++) {
		for (uint8_t x = 0; x < IOS_HAL_LCD_WIDTH; x++) {
			if (s_lcd[y][x]) {
				uint32_t bit = (uint32_t)y * IOS_HAL_LCD_WIDTH + x;
				out_bits_64[bit / 8] |= (uint8_t)(0x80 >> (bit % 8));
			}
		}
	}
	uint8_t icons = 0;
	for (uint8_t i = 0; i < IOS_HAL_ICON_COUNT; i++) {
		if (s_icons[i]) {
			icons |= (uint8_t)(1 << i);
		}
	}
	*out_icons = icons;
}

bool ios_hal_get_icon(uint8_t icon)
{
	if (icon >= IOS_HAL_ICON_COUNT) {
		return false;
	}
	return s_icons[icon];
}

void ios_hal_set_button(int btn, bool pressed)
{
	if (btn < 0 || btn > 3) {
		return;
	}
	tamalib_set_button((button_t)btn, pressed ? BTN_STATE_PRESSED : BTN_STATE_RELEASED);
}

bool ios_hal_tone_on(void)
{
	return s_tone_on;
}

uint32_t ios_hal_tone_freq_dhz(void)
{
	return s_tone_freq_dhz;
}

uint64_t ios_hal_step_count(void)
{
	return s_step_count;
}

uint32_t ios_hal_elapsed_us(void)
{
	return s_get_timestamp();
}

uint64_t ios_hal_screen_update_count(void)
{
	return s_screen_update_count;
}

uint64_t ios_hal_error_count(void)
{
	return s_error_count;
}

/* iOS port: save/restore, on top of TamaLib's own cpu_get_state() -- see
 * that function's own doc comment in cpu.h for why its fields (not
 * next_pc, not the input pins, not the speed/ref-timestamp bookkeeping)
 * are exactly what's needed to resume correctly: cpu_step() always
 * recomputes next_pc fresh from pc at the start of each step, button pins
 * are correctly reset to "released" by hw_init() on the next
 * ios_hal_start(), and the speed/ref-timestamp fields are re-derived from
 * the freq passed to that same call. Fixed, manually-laid-out format
 * (not a struct dump) so there's no compiler-dependent padding to worry
 * about matching between a save and a later load. */

#define IOS_HAL_STATE_VERSION 1

static uint32_t s_cursor_put_u8(uint8_t *buf, uint32_t pos, uint32_t cap, uint8_t v)
{
	if (pos < cap) {
		buf[pos] = v;
	}
	return pos + 1;
}

static uint32_t s_cursor_put_u16(uint8_t *buf, uint32_t pos, uint32_t cap, uint16_t v)
{
	pos = s_cursor_put_u8(buf, pos, cap, (uint8_t)(v & 0xFF));
	pos = s_cursor_put_u8(buf, pos, cap, (uint8_t)((v >> 8) & 0xFF));
	return pos;
}

static uint32_t s_cursor_put_u32(uint8_t *buf, uint32_t pos, uint32_t cap, uint32_t v)
{
	pos = s_cursor_put_u16(buf, pos, cap, (uint16_t)(v & 0xFFFF));
	pos = s_cursor_put_u16(buf, pos, cap, (uint16_t)((v >> 16) & 0xFFFF));
	return pos;
}

static uint32_t s_cursor_get_u8(const uint8_t *buf, uint32_t pos, uint32_t len, uint8_t *out)
{
	*out = (pos < len) ? buf[pos] : 0;
	return pos + 1;
}

static uint32_t s_cursor_get_u16(const uint8_t *buf, uint32_t pos, uint32_t len, uint16_t *out)
{
	uint8_t lo, hi;
	pos = s_cursor_get_u8(buf, pos, len, &lo);
	pos = s_cursor_get_u8(buf, pos, len, &hi);
	*out = (uint16_t)(lo | (hi << 8));
	return pos;
}

static uint32_t s_cursor_get_u32(const uint8_t *buf, uint32_t pos, uint32_t len, uint32_t *out)
{
	uint16_t lo, hi;
	pos = s_cursor_get_u16(buf, pos, len, &lo);
	pos = s_cursor_get_u16(buf, pos, len, &hi);
	*out = (uint32_t)lo | ((uint32_t)hi << 16);
	return pos;
}

uint32_t ios_hal_state_size(void)
{
	/* version(4) + pc,x,y(2 each=6) + a,b,np,sp,flags(1 each=5) +
	 * tick_counter + 8 clk timers + prog_timer_timestamp (4 each=40) +
	 * prog_timer_enabled,data,rld(1 each=3) + call_depth(4) +
	 * INT_SLOT_NUM interrupts x 4 bytes each + cpu_halted(1) +
	 * MEM_BUFFER_SIZE memory + LCD bits + icons + tone_on(1) +
	 * tone_freq_dhz(4) + saved elapsed_us(4) */
	return 4 + 6 + 5 + 40 + 3 + 4 + (INT_SLOT_NUM * 4) + 1 + MEM_BUFFER_SIZE
		+ (IOS_HAL_LCD_WIDTH * IOS_HAL_LCD_HEIGHT) + IOS_HAL_ICON_COUNT + 1 + 4 + 4;
}

uint32_t ios_hal_save_state(uint8_t *out_buffer, uint32_t out_capacity)
{
	state_t *state = cpu_get_state();
	uint32_t pos = 0;
	uint32_t needed = ios_hal_state_size();

	if (out_capacity < needed) {
		return 0;
	}

	pos = s_cursor_put_u32(out_buffer, pos, out_capacity, IOS_HAL_STATE_VERSION);
	pos = s_cursor_put_u16(out_buffer, pos, out_capacity, *state->pc);
	pos = s_cursor_put_u16(out_buffer, pos, out_capacity, *state->x);
	pos = s_cursor_put_u16(out_buffer, pos, out_capacity, *state->y);
	pos = s_cursor_put_u8(out_buffer, pos, out_capacity, *state->a);
	pos = s_cursor_put_u8(out_buffer, pos, out_capacity, *state->b);
	pos = s_cursor_put_u8(out_buffer, pos, out_capacity, *state->np);
	pos = s_cursor_put_u8(out_buffer, pos, out_capacity, *state->sp);
	pos = s_cursor_put_u8(out_buffer, pos, out_capacity, *state->flags);
	pos = s_cursor_put_u32(out_buffer, pos, out_capacity, *state->tick_counter);
	pos = s_cursor_put_u32(out_buffer, pos, out_capacity, *state->clk_timer_2hz_timestamp);
	pos = s_cursor_put_u32(out_buffer, pos, out_capacity, *state->clk_timer_4hz_timestamp);
	pos = s_cursor_put_u32(out_buffer, pos, out_capacity, *state->clk_timer_8hz_timestamp);
	pos = s_cursor_put_u32(out_buffer, pos, out_capacity, *state->clk_timer_16hz_timestamp);
	pos = s_cursor_put_u32(out_buffer, pos, out_capacity, *state->clk_timer_32hz_timestamp);
	pos = s_cursor_put_u32(out_buffer, pos, out_capacity, *state->clk_timer_64hz_timestamp);
	pos = s_cursor_put_u32(out_buffer, pos, out_capacity, *state->clk_timer_128hz_timestamp);
	pos = s_cursor_put_u32(out_buffer, pos, out_capacity, *state->clk_timer_256hz_timestamp);
	pos = s_cursor_put_u32(out_buffer, pos, out_capacity, *state->prog_timer_timestamp);
	pos = s_cursor_put_u8(out_buffer, pos, out_capacity, *state->prog_timer_enabled);
	pos = s_cursor_put_u8(out_buffer, pos, out_capacity, *state->prog_timer_data);
	pos = s_cursor_put_u8(out_buffer, pos, out_capacity, *state->prog_timer_rld);
	pos = s_cursor_put_u32(out_buffer, pos, out_capacity, *state->call_depth);
	for (int i = 0; i < INT_SLOT_NUM; i++) {
		pos = s_cursor_put_u8(out_buffer, pos, out_capacity, state->interrupts[i].factor_flag_reg);
		pos = s_cursor_put_u8(out_buffer, pos, out_capacity, state->interrupts[i].mask_reg);
		pos = s_cursor_put_u8(out_buffer, pos, out_capacity, state->interrupts[i].triggered);
		pos = s_cursor_put_u8(out_buffer, pos, out_capacity, state->interrupts[i].vector);
	}
	pos = s_cursor_put_u8(out_buffer, pos, out_capacity, *state->cpu_halted);
	for (uint32_t i = 0; i < MEM_BUFFER_SIZE; i++) {
		pos = s_cursor_put_u8(out_buffer, pos, out_capacity, state->memory[i]);
	}
	for (uint8_t y = 0; y < IOS_HAL_LCD_HEIGHT; y++) {
		for (uint8_t x = 0; x < IOS_HAL_LCD_WIDTH; x++) {
			pos = s_cursor_put_u8(out_buffer, pos, out_capacity, s_lcd[y][x] ? 1 : 0);
		}
	}
	for (int i = 0; i < IOS_HAL_ICON_COUNT; i++) {
		pos = s_cursor_put_u8(out_buffer, pos, out_capacity, s_icons[i] ? 1 : 0);
	}
	pos = s_cursor_put_u8(out_buffer, pos, out_capacity, s_tone_on ? 1 : 0);
	pos = s_cursor_put_u32(out_buffer, pos, out_capacity, s_tone_freq_dhz);
	pos = s_cursor_put_u32(out_buffer, pos, out_capacity, s_get_timestamp());

	return pos;
}

bool ios_hal_load_state(const uint8_t *data, uint32_t len)
{
	state_t *state = cpu_get_state();
	uint32_t pos = 0;
	uint32_t version;
	uint16_t u16;
	uint8_t u8;
	uint32_t saved_elapsed_us;

	if (len < ios_hal_state_size()) {
		return false;
	}

	pos = s_cursor_get_u32(data, pos, len, &version);
	if (version != IOS_HAL_STATE_VERSION) {
		return false;
	}

	pos = s_cursor_get_u16(data, pos, len, &u16); *state->pc = u16;
	pos = s_cursor_get_u16(data, pos, len, &u16); *state->x = u16;
	pos = s_cursor_get_u16(data, pos, len, &u16); *state->y = u16;
	pos = s_cursor_get_u8(data, pos, len, &u8); *state->a = u8;
	pos = s_cursor_get_u8(data, pos, len, &u8); *state->b = u8;
	pos = s_cursor_get_u8(data, pos, len, &u8); *state->np = u8;
	pos = s_cursor_get_u8(data, pos, len, &u8); *state->sp = u8;
	pos = s_cursor_get_u8(data, pos, len, &u8); *state->flags = u8;
	pos = s_cursor_get_u32(data, pos, len, state->tick_counter);
	pos = s_cursor_get_u32(data, pos, len, state->clk_timer_2hz_timestamp);
	pos = s_cursor_get_u32(data, pos, len, state->clk_timer_4hz_timestamp);
	pos = s_cursor_get_u32(data, pos, len, state->clk_timer_8hz_timestamp);
	pos = s_cursor_get_u32(data, pos, len, state->clk_timer_16hz_timestamp);
	pos = s_cursor_get_u32(data, pos, len, state->clk_timer_32hz_timestamp);
	pos = s_cursor_get_u32(data, pos, len, state->clk_timer_64hz_timestamp);
	pos = s_cursor_get_u32(data, pos, len, state->clk_timer_128hz_timestamp);
	pos = s_cursor_get_u32(data, pos, len, state->clk_timer_256hz_timestamp);
	pos = s_cursor_get_u32(data, pos, len, state->prog_timer_timestamp);
	pos = s_cursor_get_u8(data, pos, len, &u8); *state->prog_timer_enabled = u8;
	pos = s_cursor_get_u8(data, pos, len, &u8); *state->prog_timer_data = u8;
	pos = s_cursor_get_u8(data, pos, len, &u8); *state->prog_timer_rld = u8;
	pos = s_cursor_get_u32(data, pos, len, state->call_depth);
	for (int i = 0; i < INT_SLOT_NUM; i++) {
		pos = s_cursor_get_u8(data, pos, len, &u8); state->interrupts[i].factor_flag_reg = u8;
		pos = s_cursor_get_u8(data, pos, len, &u8); state->interrupts[i].mask_reg = u8;
		pos = s_cursor_get_u8(data, pos, len, &u8); state->interrupts[i].triggered = u8;
		pos = s_cursor_get_u8(data, pos, len, &u8); state->interrupts[i].vector = u8;
	}
	pos = s_cursor_get_u8(data, pos, len, &u8); *state->cpu_halted = u8;
	for (uint32_t i = 0; i < MEM_BUFFER_SIZE; i++) {
		pos = s_cursor_get_u8(data, pos, len, &u8);
		state->memory[i] = u8;
	}
	for (uint8_t y = 0; y < IOS_HAL_LCD_HEIGHT; y++) {
		for (uint8_t x = 0; x < IOS_HAL_LCD_WIDTH; x++) {
			pos = s_cursor_get_u8(data, pos, len, &u8);
			s_lcd[y][x] = u8 ? true : false;
		}
	}
	for (int i = 0; i < IOS_HAL_ICON_COUNT; i++) {
		pos = s_cursor_get_u8(data, pos, len, &u8);
		s_icons[i] = u8 ? true : false;
	}
	pos = s_cursor_get_u8(data, pos, len, &u8); s_tone_on = u8 ? true : false;
	pos = s_cursor_get_u32(data, pos, len, &s_tone_freq_dhz);
	pos = s_cursor_get_u32(data, pos, len, &saved_elapsed_us);

	/* Rebase the HAL's clock so ios_hal_elapsed_us() continues from
	 * saved_elapsed_us instead of the near-0 value ios_hal_start() just
	 * set it to -- same rebasing math ios_hal_set_fast_forward() already
	 * uses when leaving fast-forward, applied here to s_start_ts
	 * directly since there's no real/fast-forward split to go through
	 * yet (this runs right after ios_hal_start(), before any stepping). */
	os_unfair_lock_lock(&s_clock_lock);
	{
		struct timespec now;
		clock_gettime(CLOCK_MONOTONIC, &now);
		uint64_t back_us = saved_elapsed_us;
		s_start_ts = now;
		s_start_ts.tv_sec -= (time_t)(back_us / 1000000);
		int64_t rem_ns = (int64_t)(back_us % 1000000) * 1000;
		if (rem_ns > s_start_ts.tv_nsec) {
			s_start_ts.tv_sec -= 1;
			s_start_ts.tv_nsec += 1000000000;
		}
		s_start_ts.tv_nsec -= rem_ns;
	}
	os_unfair_lock_unlock(&s_clock_lock);

	/* cpu.c's own pacing baseline (ref_ts, static to cpu.c, not part of
	 * state_t) was just synced to ~0 by ios_hal_start()'s cpu_init() --
	 * correct for a fresh boot, but now stale against the elapsed value
	 * this just rebased s_start_ts to. Left unsynced, the first step
	 * after a load computes a deadline near ref_ts (~0) and hands it to
	 * sleep_until(): harmless under real-time pacing (a negative delta
	 * just skips sleeping and ref_ts organically catches up over
	 * subsequent steps), but under fast-forward, sleep_until()
	 * unconditionally overwrites the HAL's clock with that near-0
	 * deadline -- snapping ios_hal_elapsed_us() straight back down and
	 * making a catch-up pass's own elapsed-time bookkeeping think it's
	 * already past its target after a single step. Found exactly this
	 * way: a synthetic backlog produced a resumed Tama barely advanced
	 * at all. cpu_sync_ref_timestamp() is TamaLib's own public function
	 * for this resync, called from cpu_reset() for the same reason. */
	cpu_sync_ref_timestamp();

	return true;
}
