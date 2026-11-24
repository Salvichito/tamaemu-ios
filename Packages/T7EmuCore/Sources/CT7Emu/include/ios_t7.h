/* iOS port: the public C entry points this port adds on top of T7Emu's own
 * API (t7.h), implemented in ios_t7_compat.c. Not upstream source. See
 * CREDITS.md. Mirrors the role ios_hal.h plays for the other vendored core
 * in this app (Packages/TamaLibCore). */
#ifndef _IOS_T7_H_
#define _IOS_T7_H_

#include <stdbool.h>
#include <stdint.h>

#define IOS_T7_LCD_WIDTH  48
#define IOS_T7_LCD_HEIGHT 31
#define IOS_T7_ICON_COUNT 10

/* romBytes/romLen: a 640 KB Tama-Go or 768 KB Tamagotchi Friends flash
 * dump, user-supplied (never bundled by this project). Copied into a
 * buffer this port owns -- the caller's bytes don't need to outlive this
 * call. Returns true on success. Call ios_t7_eeprom_load() right after,
 * if resuming an existing save, before the first ios_t7_step_frame(). */
bool ios_t7_start(const uint8_t *romBytes, uint32_t romLen);

void ios_t7_stop(void);

/* True once started, if the loaded ROM is the 768 KB Friends image rather
 * than the 640 KB Tama-Go image (t7_is_friends(), auto-detected from the
 * ROM's reset vectors). */
bool ios_t7_is_friends(void);

/* Runs the core for one 60 Hz frame's worth of cycles (T7_CLOCK_RATE / 60),
 * firing the video IRQ/NMI at the real rate internally. Returns the actual
 * number of cycles consumed (may differ slightly from the request). */
uint32_t ios_t7_step_frame(void);

void ios_t7_reset(void);

/* btn: 0=A, 1=B, 2=C -- matches T7_BTN_A/B/C's left-to-right physical
 * layout, same convention as every other device in this app. */
void ios_t7_set_button(int btn, bool pressed);

/* out_pixels must hold at least IOS_T7_LCD_WIDTH*IOS_T7_LCD_HEIGHT bytes,
 * row-major, one byte per pixel (0..3 = grayscale level). out_icons must
 * hold at least IOS_T7_ICON_COUNT bytes, one byte per icon (0..3). */
void ios_t7_get_frame(uint8_t *out_pixels, uint8_t *out_icons);

/* Instantaneous buzzer state for this frame (polled once per frame, same
 * cadence as ios_t7_step_frame). Not event-accurate against t7_sound.h's
 * finer cycle-timestamped tone queue -- good enough for a square-wave
 * piezo buzzer, same simplification already made for this app's other
 * cores' AudioOutput integration. */
bool ios_t7_tone_on(void);
uint32_t ios_t7_tone_freq_hz(void);

/* Real sound (the core's own timer + DAC emulation). Off after
 * ios_t7_start (catch-up: much faster without it). ios_t7_sound_live(true,
 * rate): live play -- emulate the sound hardware and make a clean 16-bit
 * mono stream at `rate` Hz; call it before ios_t7_load_state so the saved
 * sound-timer phase is restored. false: back off.
 * ios_t7_sound_capture: pause/resume making samples (audio engine idle).
 * ios_t7_sound_pull/skip_to: audio thread only (single reader); pull is
 * rate-controlled toward `target` buffered samples. ios_t7_sound_busy: a
 * melody or tone is playing right now. */
void ios_t7_sound_live(bool on, uint32_t sample_rate);
void ios_t7_sound_capture(bool on);
uint32_t ios_t7_sound_pull(int16_t *out, uint32_t n, uint32_t target);
void ios_t7_sound_skip_to(uint32_t keep);
bool ios_t7_sound_busy(void);

/* The attention ("bell", bottom-right) icon is lit: the Tama is calling.
 * Icon 9 in t7.h's layout; fan guides put the Tama-Go's attention icon
 * bottom right, lit until answered or 15 minutes pass (a care miss).
 * Not yet seen lit in this port's own testing. */
bool ios_t7_attention_on(void);

/* The emulated 4 KB I2C EEPROM -- the Tama's own game save (character,
 * growth stage, stats). Same split as real hardware: this is what
 * survives a power-loss there, independent of CPU/RAM state below.
 * ios_t7_eeprom_save's buffer size is self-describing (count + key +
 * 256 B per used page), capped well under 1 KB in practice (16 pages);
 * pass bufsize 0 (out may be NULL) first to get the size actually needed. */
uint32_t ios_t7_eeprom_save(uint8_t *out, uint32_t bufsize);
bool ios_t7_eeprom_load(const uint8_t *data, uint32_t len);

/* Full CPU + WRAM + DRAM + bank-select snapshot (t7_serialize_state's own
 * format) -- not what real hardware preserves across power-loss, but what
 * lets this port resume play exactly where it left off instead of a cold
 * boot each time, same UX this app's other two cores already give every
 * device. Pass bufsize 0 (out may be NULL) first to get the size needed. */
uint32_t ios_t7_save_state(uint8_t *out, uint32_t bufsize);
bool ios_t7_load_state(const uint8_t *data, uint32_t len);

/* Diagnostics for a smoke test, not play. */
uint64_t ios_t7_step_count(void);

#endif /* _IOS_T7_H_ */
