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

static timestamp_t s_get_timestamp(void)
{
	if (s_fast_forward) {
		return s_ff_now;
	}
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	uint64_t us = (uint64_t)(now.tv_sec - s_start_ts.tv_sec) * 1000000ULL
		+ (uint64_t)(now.tv_nsec - s_start_ts.tv_nsec) / 1000ULL;
	return (timestamp_t)us;
}

static void s_sleep_until(timestamp_t ts)
{
	if (s_fast_forward) {
		s_ff_now = ts;
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
	if (enabled == s_fast_forward) {
		return;
	}
	if (enabled) {
		/* Enter fast-forward from whatever real time it is now. */
		s_ff_now = s_get_timestamp();
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
