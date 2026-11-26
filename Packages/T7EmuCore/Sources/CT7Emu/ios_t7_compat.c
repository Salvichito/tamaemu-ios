/* iOS port: implements the compat API the vendored core expects
 * (pebble_compat.h's logging/resource/persist surface, plus the two
 * figure-accessory externs t7_memory.c declares directly), and the
 * ios_t7.h entry points this port adds on top of t7.h. Not upstream
 * source. See CREDITS.md.
 *
 * No file I/O happens in here on purpose, matching this app's other
 * vendored core (TamaLibCore/hal_ios.c): the Swift side owns all disk
 * access (SavePaths) and hands this layer plain buffers. */

#include "t7.h"
#include "t7_eeprom.h"
#include "t7_sound.h"
#include "ios_t7.h"
#include "t7_internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

/* ----- Logging ------------------------------------------------------- */

void tama_log(const char *fmt, ...)
{
  va_list args;
  va_start(args, fmt);
  vfprintf(stderr, fmt, args);
  va_end(args);
}

/* ----- Resource API (ROM), backed by a copy of the caller's buffer --- */

static uint8_t *s_rom_buf = NULL;
static size_t   s_rom_len = 0;

static void rom_unload(void)
{
  if (s_rom_buf) { free(s_rom_buf); s_rom_buf = NULL; s_rom_len = 0; }
}

static bool rom_load(const uint8_t *bytes, uint32_t len)
{
  rom_unload();
  if (!bytes || len == 0) return false;

  uint8_t *buf = (uint8_t *)malloc(len);
  if (!buf) return false;

  memcpy(buf, bytes, len);
  s_rom_buf = buf;
  s_rom_len = len;
  return true;
}

ResHandle resource_get_handle(int id)
{
  (void)id;
  return s_rom_buf ? 1 : 0;
}

size_t resource_size(ResHandle h)
{
  (void)h;
  return s_rom_len;
}

size_t resource_load_byte_range(ResHandle h, size_t offset, uint8_t *out, size_t len)
{
  (void)h;
  if (!s_rom_buf || !out) return 0;
  if (offset >= s_rom_len) return 0;
  size_t avail = s_rom_len - offset;
  size_t n = len < avail ? len : avail;
  memcpy(out, s_rom_buf + offset, n);
  return n;
}

const uint8_t *t7_compat_rom_mapped(void)
{
  return s_rom_buf;
}

/* These two compat hooks (declared in pebble_compat.h, called from
 * t7_init/t7_release) have no file-backed meaning here -- Swift decides
 * ROM identity by which bytes it hands ios_t7_start(), and the EEPROM's
 * own lifetime is just this process's memory until the Swift side asks
 * for a snapshot via ios_t7_eeprom_save(). Both still need to exist and
 * do nothing, since t7_init/t7_eeprom_init call the real pebble_compat.h
 * API, not these ios_t7_* ones. */
void t7_compat_set_rom_path(const char *path) { (void)path; }
void t7_compat_set_eeprom_path(const char *path) { (void)path; }

/* ----- Persist API (EEPROM), backed by an in-memory slot table --------
 *
 * The core only ever touches up to 16 keys (t7_eeprom.c's 256-byte pages),
 * but nothing here assumes that -- a small fixed table of (key, 256 B)
 * slots, linear-scanned, is simpler than reverse-engineering the core's
 * own key numbering and just as fast at this scale. */

#define IOS_T7_PERSIST_SLOTS 32
#define IOS_T7_PERSIST_SLOT_SIZE 256

typedef struct {
  bool     used;
  uint32_t key;
  uint8_t  data[IOS_T7_PERSIST_SLOT_SIZE];
} ios_t7_persist_slot_t;

static ios_t7_persist_slot_t s_persist[IOS_T7_PERSIST_SLOTS];

static ios_t7_persist_slot_t *persist_find(uint32_t key, bool create)
{
  for (int i = 0; i < IOS_T7_PERSIST_SLOTS; i++) {
    if (s_persist[i].used && s_persist[i].key == key) return &s_persist[i];
  }
  if (!create) return NULL;
  for (int i = 0; i < IOS_T7_PERSIST_SLOTS; i++) {
    if (!s_persist[i].used) {
      s_persist[i].used = true;
      s_persist[i].key = key;
      memset(s_persist[i].data, 0, IOS_T7_PERSIST_SLOT_SIZE);
      return &s_persist[i];
    }
  }
  return NULL; /* table full -- shouldn't happen at this core's scale */
}

bool persist_exists(uint32_t key)
{
  return persist_find(key, false) != NULL;
}

int persist_read_data(uint32_t key, void *buf, size_t size)
{
  ios_t7_persist_slot_t *s = persist_find(key, false);
  if (!s) return -1;
  size_t n = size < IOS_T7_PERSIST_SLOT_SIZE ? size : IOS_T7_PERSIST_SLOT_SIZE;
  memcpy(buf, s->data, n);
  return (int)n;
}

status_t persist_write_data(uint32_t key, const void *buf, size_t size)
{
  ios_t7_persist_slot_t *s = persist_find(key, true);
  if (!s) return -1;
  size_t n = size < IOS_T7_PERSIST_SLOT_SIZE ? size : IOS_T7_PERSIST_SLOT_SIZE;
  memset(s->data, 0, IOS_T7_PERSIST_SLOT_SIZE);
  memcpy(s->data, buf, n);
  return S_SUCCESS;
}

status_t persist_delete(uint32_t key)
{
  ios_t7_persist_slot_t *s = persist_find(key, false);
  if (!s) return S_SUCCESS;
  s->used = false;
  return S_SUCCESS;
}

void persist_flush_to_disk(void) { /* no-op: see ios_t7_eeprom_save */ }
int persist_page_count(void) { return 0; }
int persist_page_size(void) { return 0; }
int persist_backup_page(int page, uint8_t *out) { (void)page; (void)out; return 0; }
void persist_restore_page(int page, const uint8_t *in) { (void)page; (void)in; }

/* ----- Figure accessory (replaces upstream figure_data.c). The figure's
 * flash contents are a user-imported dump, copied into a buffer this port
 * owns. t7_memory.c reads it over its emulated SPI bus; the "a figure is
 * plugged in" pins are t7_figure_set (Paramix uses id 1 for every figure).
 * Only touched from the thread stepping the core (or before it starts). */

static unsigned char *s_fig_data = NULL;
static unsigned int s_fig_len = 0;

const unsigned char *figure_rom_ptr(void) { return s_fig_data; }
unsigned int figure_rom_length(void) { return s_fig_len; }

void ios_t7_figure_remove(void)
{
  t7_figure_set(0);
  free(s_fig_data);
  s_fig_data = NULL;
  s_fig_len = 0;
}

bool ios_t7_figure_insert(const uint8_t *data, uint32_t len)
{
  ios_t7_figure_remove();
  if (!data || len < 3) return false;
  s_fig_data = malloc(len);
  if (!s_fig_data) return false;
  memcpy(s_fig_data, data, len);
  s_fig_len = len;
  t7_figure_set(1);
  return true;
}

/* ----- ios_t7.h entry points ------------------------------------------- */

/* See ios_t7_step_frame. */
static int64_t s_cycle_debt = 0;   /* cycles run beyond what was owed so far */
static uint32_t s_frac = 0;        /* 0..59: sixtieths of a cycle owed */

bool ios_t7_start(const uint8_t *romBytes, uint32_t romLen)
{
  if (!rom_load(romBytes, romLen)) return false;
  ios_t7_figure_remove();   /* every start begins with nothing plugged in */
  memset(s_persist, 0, sizeof(s_persist));
  s_cycle_debt = 0; s_frac = 0;
  if (!t7_init()) return false;
  /* Sound starts off: catch-up runs without it. With the sound hardware on,
   * the melody sequencer's timer IRQ fires 512 times a second even in
   * silence, which defeats T7_IDLE (Tama-Go catch-up ~1800x -> ~200x real
   * time). Live play turns it on with ios_t7_sound_live. Upstream supports
   * switching this at runtime (t7_snd_set_mode). */
  t7_snd_set_mode(0);
  t7_snd_capture(0);
  t7_snd_synth(0);
  return true;
}

void ios_t7_sound_live(bool on, uint32_t sample_rate)
{
  if (on) {
    t7_snd_config(T7_CLOCK_RATE, sample_rate ? sample_rate : 48000);
    t7_snd_volume(100);
    t7_snd_set_mode(1); /* timers re-derived from the registers */
    t7_snd_synth(1);    /* clean band-limited square, as upstream's Android build */
    t7_snd_capture(1);
  } else {
    t7_snd_capture(0);
    t7_snd_synth(0);
    t7_snd_set_mode(0);
  }
}

void ios_t7_sound_capture(bool on)
{
  t7_snd_capture(on ? 1 : 0);
}

uint32_t ios_t7_sound_pull(int16_t *out, uint32_t n, uint32_t target)
{
  __atomic_thread_fence(__ATOMIC_ACQUIRE);
  return t7_snd_pull(out, n, target);
}

void ios_t7_sound_skip_to(uint32_t keep)
{
  t7_snd_skip_to(keep);
}

bool ios_t7_set_clock(int hour, int minute, int second)
{
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59 || second < 0 || second > 59) return false;
  /* Found by watching a running Tama-Go and Friends headless: both keep
   * the game clock as plain binary bytes, hour 0x0306 and minute 0x0307
   * (0-23 / 0-59), with the second at t7_rtc_sec_addr(). Rollover past
   * midnight after a write was checked on both. Before the player has
   * set the clock (fresh boot setup) the hour byte is not a valid hour,
   * so leave it alone then. */
  if (t7_ram_read(0x0306) > 23) return false;
  t7_ram_write(0x0306, (uint8_t)hour);
  t7_ram_write(0x0307, (uint8_t)minute);
  t7_ram_write(t7_rtc_sec_addr(), (uint8_t)second);
  return true;
}

bool ios_t7_attention_on(void)
{
  uint8_t icons[IOS_T7_ICON_COUNT];
  t7_get_icons(icons);
  return icons[9] != 0;
}

bool ios_t7_sound_busy(void)
{
  return t7_snd_busy() != 0;
}

void ios_t7_stop(void)
{
  ios_t7_figure_remove();
  t7_release();
  rom_unload();
}

bool ios_t7_is_friends(void)
{
  return t7_is_friends() != 0;
}

static uint64_t s_frame_count = 0;

/* One 60 Hz frame is 66666.67 cycles, and the core may run a few cycles
 * past what it was asked for (it finishes the instruction). Both leftovers
 * are carried into the next frame, so 60 frames are exactly T7_CLOCK_RATE
 * cycles -- the game clock is driven by cycles, so without this it drifted
 * by a few seconds a day. */

uint32_t ios_t7_step_frame(void)
{
  s_frame_count++;
  int64_t want = T7_CLOCK_RATE / 60;
  s_frac += T7_CLOCK_RATE % 60;
  if (s_frac >= 60) { s_frac -= 60; want++; }
  want -= s_cycle_debt;
  if (want < 1) { s_cycle_debt = -want; return 0; }   /* already ran this frame's share */
  uint32_t spent = t7_step_cycles((uint32_t)want);
  s_cycle_debt = (int64_t)spent - want;
  __atomic_thread_fence(__ATOMIC_RELEASE);   /* audio samples visible to the audio thread */
  return spent;
}

void ios_t7_reset(void)
{
  t7_reset();
}

void ios_t7_set_button(int btn, bool pressed)
{
  static uint8_t mask = 0;
  uint8_t bit = (btn == 0) ? T7_BTN_A : (btn == 1) ? T7_BTN_B : (btn == 2) ? T7_BTN_C : 0;
  if (pressed) mask |= bit; else mask &= ~bit;
  t7_set_buttons(mask);
}

void ios_t7_get_frame(uint8_t *out_pixels, uint8_t *out_icons)
{
  if (out_pixels) t7_get_display(out_pixels);
  if (out_icons) t7_get_icons(out_icons);
}

bool ios_t7_tone_on(void)
{
  return t7_snd_active() != 0;
}

uint32_t ios_t7_tone_freq_hz(void)
{
  uint8_t level = 0;
  return t7_snd_tone_hz(&level);
}

uint32_t ios_t7_eeprom_save(uint8_t *out, uint32_t bufsize)
{
  t7_eeprom_flush(); /* make sure every dirty page is in s_persist first */

  uint32_t count = 0;
  for (int i = 0; i < IOS_T7_PERSIST_SLOTS; i++) if (s_persist[i].used) count++;

  uint32_t needed = (uint32_t)sizeof(count)
    + count * (uint32_t)(sizeof(uint32_t) + IOS_T7_PERSIST_SLOT_SIZE);
  if (!out || bufsize < needed) return needed;

  uint8_t *p = out;
  memcpy(p, &count, sizeof(count)); p += sizeof(count);
  for (int i = 0; i < IOS_T7_PERSIST_SLOTS; i++) {
    if (!s_persist[i].used) continue;
    memcpy(p, &s_persist[i].key, sizeof(uint32_t)); p += sizeof(uint32_t);
    memcpy(p, s_persist[i].data, IOS_T7_PERSIST_SLOT_SIZE); p += IOS_T7_PERSIST_SLOT_SIZE;
  }
  return needed;
}

bool ios_t7_eeprom_load(const uint8_t *data, uint32_t len)
{
  if (!data || len < sizeof(uint32_t)) return false;

  memset(s_persist, 0, sizeof(s_persist));

  const uint8_t *p = data;
  uint32_t remaining = len;
  uint32_t count;
  memcpy(&count, p, sizeof(count)); p += sizeof(count); remaining -= sizeof(count);
  if (count > IOS_T7_PERSIST_SLOTS) return false;

  uint32_t entrySize = sizeof(uint32_t) + IOS_T7_PERSIST_SLOT_SIZE;
  if (remaining < count * entrySize) return false;

  for (uint32_t i = 0; i < count; i++) {
    uint32_t key;
    memcpy(&key, p, sizeof(key)); p += sizeof(key);
    s_persist[i].used = true;
    s_persist[i].key = key;
    memcpy(s_persist[i].data, p, IOS_T7_PERSIST_SLOT_SIZE); p += IOS_T7_PERSIST_SLOT_SIZE;
  }

  /* The core's own EEPROM state machine (bus phase, shift register, etc)
   * is reset to its power-off idle state by t7_eeprom_init(); re-run it
   * now so it re-reads from the pages we just loaded, same as it would
   * on a real t7_init(). */
  t7_eeprom_init();
  return true;
}

/* t7_cpu.c keeps the live flags outside g_cpu (see t7_cpu_set_p there):
 * copy them into g_cpu.p before serializing, and back out after loading. */
uint8_t t7_dbg_p(void);
void t7_cpu_set_p(uint8_t p);

/* After t7_serialize_state's own bytes, this port appends a small trailer
 * with timing state the core's format leaves out: this file's cycle debt and
 * fraction (ios_t7_step_frame) and t7.c's two timer accumulators. Without it
 * every resume dropped a few cycles, enough for the game's randomness to take
 * a different path after ~100 resumes. Older saves without the trailer still
 * load (the core accepts a longer buffer; the trailer is then just absent). */
#define IOS_T7_TRAILER_MAGIC 0x31534F69u  /* "iOS1" */
#define IOS_T7_TRAILER_SIZE  24u
/* "iOS2" = iOS1 + the two sound timers' phase (t7_snd_get_timers): run flags
 * (2 bytes, padded to 8) and cycles left to the next overflow (2 x int64,
 * 16.16 fixed point). iOS1 saves still load; their sound timers restart. */
#define IOS_T7_TRAILER2_MAGIC 0x32534F69u /* "iOS2" */
#define IOS_T7_TRAILER2_SIZE  48u
void t7_get_timer_acc(uint32_t *video, uint32_t *tbh);
void t7_set_timer_acc(uint32_t video, uint32_t tbh);

uint32_t ios_t7_save_state(uint8_t *out, uint32_t bufsize)
{
  uint32_t core = t7_serialize_state(NULL, 0);
  uint32_t needed = core + IOS_T7_TRAILER2_SIZE;
  if (!out || bufsize < needed) return needed;
  if (!g_initialised) return 0;
  g_cpu.p = t7_dbg_p();
  if (t7_serialize_state(out, core) != core) return 0;
  uint8_t *p = out + core;
  uint32_t magic = IOS_T7_TRAILER2_MAGIC, video, tbh;
  t7_get_timer_acc(&video, &tbh);
  memcpy(p, &magic, 4); p += 4;
  memcpy(p, &s_cycle_debt, 8); p += 8;
  memcpy(p, &s_frac, 4); p += 4;
  memcpy(p, &video, 4); p += 4;
  memcpy(p, &tbh, 4); p += 4;
  uint8_t run[8] = {0}; int64_t remain[2];
  t7_snd_get_timers(run, remain);
  memcpy(p, run, 8); p += 8;
  memcpy(p, remain, 16);
  return needed;
}

bool ios_t7_load_state(const uint8_t *data, uint32_t len)
{
  if (!t7_deserialize_state(data, len)) return false;
  t7_cpu_set_p(g_cpu.p);
  uint32_t core = t7_serialize_state(NULL, 0);
  uint32_t magic = 0;
  if (len >= core + IOS_T7_TRAILER_SIZE) memcpy(&magic, data + core, 4);
  if (magic == IOS_T7_TRAILER2_MAGIC && len < core + IOS_T7_TRAILER2_SIZE) magic = 0;
  if (magic == IOS_T7_TRAILER_MAGIC || magic == IOS_T7_TRAILER2_MAGIC) {
    const uint8_t *p = data + core + 4;
    uint32_t video, tbh;
    memcpy(&s_cycle_debt, p, 8); p += 8;
    memcpy(&s_frac, p, 4); p += 4;
    memcpy(&video, p, 4); p += 4;
    memcpy(&tbh, p, 4);
    if (s_frac >= 60) s_frac = 0;
    t7_set_timer_acc(video, tbh);
    if (magic == IOS_T7_TRAILER2_MAGIC) {
      uint8_t run[8]; int64_t remain[2];
      p += 4;
      memcpy(run, p, 8); p += 8;
      memcpy(remain, p, 16);
      t7_snd_set_timers(run, remain);
    }
  } else {
    s_cycle_debt = 0; s_frac = 0;
  }
  return true;
}

uint64_t ios_t7_step_count(void)
{
  return s_frame_count;
}

/* ----- Infrared link (Tama-Go) --------------------------------------- */

/* Upstream's T7_LINK hooks (t7_cpu.c), as Paramix Studio uses them between
 * two Paradise: each packet the game sends is taken whole and handed to the
 * other Tama's receive hook. Measured headless 2026-11-26 with two cores in
 * frame lockstep: GAME (YOU WIN / YOU LOSE, points) and VISIT (AWAY, both
 * in the host's room, guest home ~1 min later) both complete. */
bool ios_t7_link_take(uint8_t *out32)
{
  return t7_ir_tx_take(out32) != 0;
}

void ios_t7_link_give(const uint8_t *in32)
{
  t7_ir_bridge_rx(in32);
}

uint32_t ios_t7_link_activity(void)
{
  return t7_ir_activity();
}
