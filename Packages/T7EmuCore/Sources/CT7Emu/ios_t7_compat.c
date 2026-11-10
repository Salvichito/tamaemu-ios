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

/* ----- Figure accessory: not vendored (figure_data.c, Paradise-specific
 * figure ROM blobs) -- report "no figure plugged in" unconditionally. */

const unsigned char *figure_rom_ptr(void) { return NULL; }
unsigned int figure_rom_length(void) { return 0; }

/* ----- ios_t7.h entry points ------------------------------------------- */

bool ios_t7_start(const uint8_t *romBytes, uint32_t romLen)
{
  if (!rom_load(romBytes, romLen)) return false;
  memset(s_persist, 0, sizeof(s_persist));
  return t7_init();
}

void ios_t7_stop(void)
{
  t7_release();
  rom_unload();
}

bool ios_t7_is_friends(void)
{
  return t7_is_friends() != 0;
}

static uint64_t s_frame_count = 0;

uint32_t ios_t7_step_frame(void)
{
  s_frame_count++;
  return t7_step_cycles(T7_CLOCK_RATE / 60);
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

uint32_t ios_t7_save_state(uint8_t *out, uint32_t bufsize)
{
  return t7_serialize_state(out, bufsize);
}

bool ios_t7_load_state(const uint8_t *data, uint32_t len)
{
  return t7_deserialize_state(data, len);
}

uint64_t ios_t7_step_count(void)
{
  return s_frame_count;
}
