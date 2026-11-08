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
int ios_hal_start(const uint16_t *program, uint32_t program_words);

/* One emulated instruction. Paced to real time internally by TamaLib
 * itself (via sleep_until), same as a real device's clock. */
void ios_hal_step(void);

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

/* btn: 0=A (left), 1=B (middle), 2=C (right) -- matches hw.h's button_t
 * ordinals (BTN_LEFT/BTN_MIDDLE/BTN_RIGHT), which the real P1 wires to its
 * physical left-to-right A/B/C layout. BTN_TAP (3) is the touch sensor on
 * later E0C6S48 devices, unused on a plain P1. */
void ios_hal_set_button(int btn, bool pressed);

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
