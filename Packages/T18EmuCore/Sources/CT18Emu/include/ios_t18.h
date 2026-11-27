/* iOS port: the C entry points this port adds on top of T18Emu's own API
 * (t18soc.h), implemented in ios_t18_compat.c. Not upstream source. See
 * CREDITS.md. Same role as ios_t7.h for the Tama-Go/Friends core.
 *
 * There is one Meets/On core per process (the upstream core keeps its
 * guest SRAM and flash map in globals), so callers serialize access the
 * same way they do for the T7 core (EngineGate). */
#ifndef IOS_T18_H
#define IOS_T18_H

#include <stdbool.h>
#include <stdint.h>

#define IOS_T18_LCD_WIDTH  128
#define IOS_T18_LCD_HEIGHT 128
#define IOS_T18_FLASH_SIZE 0x800000u

/* True for an 8 MB Meets/On (TG18) firmware: "SPII" header, entry
 * 0x2000000C (the same test Paramix Studio uses, t18Detect in src/emu.js). */
bool ios_t18_is_firmware(const uint8_t *rom, uint32_t len);

/* Copies the 8 MB firmware into a flash buffer this port owns (the game
 * writes its save into that flash, like the real toy) and powers on.
 * Returns false if the bytes are not a Meets/On firmware. */
bool ios_t18_start(const uint8_t *rom, uint32_t len);
void ios_t18_stop(void);
bool ios_t18_running(void);

/* Runs the core for `us` microseconds of emulated time. While the game has
 * switched itself off (screen dark), this skips ahead to the next alarm
 * or key at almost no cost. */
void ios_t18_run_us(uint32_t us);

/* Sound for live play (catch-up runs without it): while on, ios_t18_run_us
 * steps in 1 ms slices and renders the buzzer as 16-bit mono at
 * `sample_rate`. capture pauses making samples (audio engine idle). pull /
 * skip_to: audio thread only; pull is rate-controlled toward `target`
 * buffered samples. busy: a tone played in the last 200 ms. */
void ios_t18_sound_live(bool on, uint32_t sample_rate);
void ios_t18_sound_capture(bool on);
uint32_t ios_t18_sound_pull(int16_t *out, uint32_t n, uint32_t target);
void ios_t18_sound_skip_to(uint32_t keep);
bool ios_t18_sound_busy(void);

/* bit 0 = A (left), bit 1 = B (middle), bit 2 = C (right). */
void ios_t18_set_buttons(int mask);

/* The last finished picture, 128x128 RGB565 (row-major). Returns a
 * counter that goes up with every new picture, so callers can skip
 * redraws. out may be NULL to only read the counter. */
uint32_t ios_t18_get_frame(uint16_t *out);
/* Screen light 0..255; 0 while the game is off (screen dark). */
int ios_t18_backlight(void);
/* Buzzer pitch in Hz right now, 0 = silent. */
uint32_t ios_t18_tone_hz(void);
/* The Tama is calling (the game's call flags), when known for this build. */
bool ios_t18_attention(void);
/* The game is running (not switched off to save power). */
bool ios_t18_power(void);

/* The toy's battery clock, local wall time. */
void ios_t18_set_time(int y, int mo, int d, int h, int mi, int s);
void ios_t18_get_time(int out6[6]);

/* Gotchi Points (16 bit in the game's Param block, +0x20), -1 if unknown. */
int ios_t18_get_points(void);
bool ios_t18_set_points(int value);

/* Session: CPU and chip state plus the 128 KB SRAM. Pass buf=NULL to get
 * the size needed. Load after ios_t18_flash_load. */
uint32_t ios_t18_save_state(uint8_t *buf, uint32_t len);
bool ios_t18_load_state(const uint8_t *buf, uint32_t len);

/* The game's own save: every 4 KB flash sector it has written since the
 * firmware was loaded (on the real toy this is what survives a battery
 * change). Pass buf=NULL to get the size needed. Load right after
 * ios_t18_start, before the first run. */
uint32_t ios_t18_flash_save(uint8_t *buf, uint32_t len);
bool ios_t18_flash_load(const uint8_t *buf, uint32_t len);

#endif
