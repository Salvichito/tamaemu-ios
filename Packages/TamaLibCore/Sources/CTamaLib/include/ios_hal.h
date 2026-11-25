/* iOS port: the public C entry points this port adds on top of TamaLib's
 * own API, implemented in hal_ios.c. Not upstream source. See CREDITS.md. */
#ifndef _IOS_HAL_H_
#define _IOS_HAL_H_

#include <stdbool.h>
#include <stdint.h>

#define IOS_HAL_LCD_WIDTH  32
#define IOS_HAL_LCD_HEIGHT 16
#define IOS_HAL_ICON_COUNT 8

/* program is TamaLib's own 12-bit-word ROM format (one unsigned short per
 * word, upper nibble unused), program_words its length. Returns 0 on
 * success, matching tamalib_init's own convention. */
int ios_hal_start(const uint16_t *program, uint32_t program_words, int model);

/* Which toy the ROM is, for the parts of the hardware the ROM alone doesn't
 * say: LCD wiring, LCD orientation, and how keys and beeps reach the chip.
 * The per-model behaviour comes from Paramix Studio's V1Emu (see CREDITS.md). */
#define IOS_HAL_MODEL_P1                0 /* P1, P2, Angel, Morino */
#define IOS_HAL_MODEL_ICON_PER_SEGMENT  1 /* Umino */
#define IOS_HAL_MODEL_YASASHII          2
#define IOS_HAL_MODEL_DIGIMON           3
/* Mothra: icon-per-segment LCD wiring, and like the Digimon it needs key
 * interrupts (cpu_kmask_fix). Measured headless 2026-11-24: without the
 * interrupts a press had to last ~0.5 s to register and the egg never hatched
 * in the runner; with the P1 wiring whole icon rows lit together. */
#define IOS_HAL_MODEL_MOTHRA            4
/* Tamaotch: icon-per-segment wiring, and its program timer runs at the speed
 * the ROM selects (cpu_prog_timer_sel_fix in cpu.c) instead of a fixed
 * 256 Hz, which made it need ~0.35 s presses. */
#define IOS_HAL_MODEL_TAMAOTCH          5
/* Genjintch: icon-per-segment wiring, key interrupts (cpu_kmask_fix) and
 * the program timer at the speed the ROM selects. Measured 2026-11-24 with
 * Tools/v1check: without key interrupts it only saw a key held across a
 * twice-a-second check, so most clock-confirm and menu presses were lost;
 * with both it hatches (~4.9 min) and every 0.08 s press registers. */
#define IOS_HAL_MODEL_GENJINTCH         6

/* One emulated instruction. Paced to real time internally by TamaLib
 * itself (via sleep_until), same as a real device's clock. */
void ios_hal_step(void);

/* Runs `count` steps back to back. For fast-forward catch-up, where the
 * cost of crossing from Swift into C once per instruction was several
 * times the cost of the instruction itself. */
void ios_hal_step_many(uint32_t count);

void ios_hal_stop(void);

bool ios_hal_get_pixel(uint8_t x, uint8_t y);
bool ios_hal_get_icon(uint8_t icon);

/* Bulk snapshot for a live view: one call instead of 512 (IOS_HAL_LCD_WIDTH
 * x IOS_HAL_LCD_HEIGHT) pixel calls per drawn frame. out_bits must hold at
 * least 64 bytes (512 pixels, row-major, bit 0 of byte 0 = x=0,y=0, MSB-
 * first within each byte). out_icons gets one bit per icon (bit i = icon
 * i). */
void ios_hal_get_frame(uint8_t *out_bits_64, uint8_t *out_icons);

/* Skips real-time pacing: the clock the core sees jumps straight to each
 * requested wake time instead of actually sleeping for it, so a long boot
 * sequence or background catch-up runs at full CPU speed instead of real
 * chip speed. Off by default (live play wants real pacing). Safe to
 * toggle on/off at any time; timestamps stay continuous across the
 * switch. */
void ios_hal_set_fast_forward(bool enabled);

/* Live-play speed multiplier (1 = real chip speed, 2 = twice as fast, ...),
 * for the app's hold-to-fast-forward. Still paced against the real clock,
 * unlike ios_hal_set_fast_forward() above, which doesn't pace at all --
 * the two must not be combined. Reset to 1 by ios_hal_start() and
 * ios_hal_stop(), so a catch-up pass can never inherit it. */
void ios_hal_set_speed(uint8_t multiplier);

/* btn: 0=A (left), 1=B (middle), 2=C (right) -- matches hw.h's button_t
 * ordinals (BTN_LEFT/BTN_MIDDLE/BTN_RIGHT), which the real P1 wires to its
 * physical left-to-right A/B/C layout. BTN_TAP (3) is the touch sensor on
 * later E0C6S48 devices, unused on a plain P1. */
void ios_hal_set_button(int btn, bool pressed);
/* 4-7 are the K10-K13 pins, the Yasashii's toilet, affection, happiness
 * and meal buttons (ignored on every other model). On the Yasashii, 0 is
 * its status button, 1 select, 2 cancel and 3 lights. */

/* Yasashii only (0 for every other model): which of its six lit care
 * buttons are on right now, one bit each. Measured 2026-11-18 with a
 * headless runner: meal, happiness and lights each blink when the toy
 * needs that care and stop once it's given; affection, status and toilet
 * are placed from the order the six run in at hatching (clockwise around
 * the real toy: top row left to right, then bottom row right to left).
 * Status/toilet were first placed the wrong way round; the user saw the
 * toilet lamp light on the status screen (2026-11-25) and they were
 * swapped. Affection is still not individually confirmed. */
#define IOS_HAL_LAMP_MEAL       (1 << 0)
#define IOS_HAL_LAMP_HAPPINESS  (1 << 1)
#define IOS_HAL_LAMP_AFFECTION  (1 << 2)
#define IOS_HAL_LAMP_TOILET     (1 << 3)
#define IOS_HAL_LAMP_LIGHTS     (1 << 4)
#define IOS_HAL_LAMP_STATUS     (1 << 5)
uint8_t ios_hal_get_lamps(void);

bool ios_hal_tone_on(void);
uint32_t ios_hal_tone_freq_dhz(void); /* deci-hertz, matches set_frequency()'s unit */

/* Diagnostics, reset by ios_hal_start(); for the smoke test, not play. */
uint64_t ios_hal_step_count(void);
uint32_t ios_hal_elapsed_us(void); /* the core's own clock, real or fast-forwarded */
uint64_t ios_hal_screen_update_count(void);
uint64_t ios_hal_error_count(void);

/* Save/restore. Fixed size, own private format (TamaLib's own cpu_get_state()
 * plus this HAL's display/tone state and its own elapsed clock) -- not
 * upstream, not meant to be read by anything but this same build. Call
 * only after ios_hal_start(); ios_hal_load_state() restores CPU, RAM and
 * display/tone state and rebases the HAL's clock so ios_hal_elapsed_us()
 * continues from the saved value instead of resetting to 0, so TamaLib's
 * own timers stay internally consistent across a save/restore. */
uint32_t ios_hal_state_size(void);
uint32_t ios_hal_save_state(uint8_t *out_buffer, uint32_t out_capacity); /* bytes written, 0 on failure */
bool ios_hal_load_state(const uint8_t *data, uint32_t len);

#endif /* _IOS_HAL_H_ */
