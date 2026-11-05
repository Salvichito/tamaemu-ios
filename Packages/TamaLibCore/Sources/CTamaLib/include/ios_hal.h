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

bool ios_hal_tone_on(void);
uint32_t ios_hal_tone_freq_dhz(void); /* deci-hertz, matches set_frequency()'s unit */

/* Diagnostics, reset by ios_hal_start(); for the smoke test, not play. */
uint64_t ios_hal_step_count(void);
uint64_t ios_hal_screen_update_count(void);
uint64_t ios_hal_error_count(void);

#endif /* _IOS_HAL_H_ */
