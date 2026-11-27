/* iOS port: the platform side of T18Emu for this app -- the guest flash and
 * SRAM buffers the core expects the host to provide, plus the entry points
 * in include/ios_t18.h. Not upstream source; modelled on the core's own PC
 * host (t18/host/ref.c in mameise/Paramix-Studio). See CREDITS.md. */
#include "ios_t18.h"
#include "t18soc.h"
#include <stdlib.h>
#include <string.h>

#define SECTOR 4096u
#define SECTORS (IOS_T18_FLASH_SIZE / SECTOR)
#define FLASH_MAGIC 0x46383154u  /* "T18F" */
#define STATE_MAGIC 0x53383154u  /* "T18S" */

static uint8_t *g_flash;
static uint8_t g_written[SECTORS];   /* sectors the game has erased or programmed */
static tg18_t *g_t;
static bool s_live, s_capture;   /* sound, see below (tentative definitions) */

/* ---- what the core asks of the platform (t18soc.h) ---- */
uint8_t t18_flash_rd(uint32_t a) { return g_flash[a & (IOS_T18_FLASH_SIZE - 1)]; }
void t18_flash_prog(uint32_t a, uint8_t b) {
    a &= IOS_T18_FLASH_SIZE - 1;
    g_flash[a] &= b;
    g_written[a / SECTOR] = 1;
}
void t18_flash_erase(uint32_t a, uint32_t size) {
    a &= IOS_T18_FLASH_SIZE - 1;
    if (a + size > IOS_T18_FLASH_SIZE) size = IOS_T18_FLASH_SIZE - a;
    memset(g_flash + a, 0xFF, size);
    for (uint32_t s = a / SECTOR; s < (a + size + SECTOR - 1) / SECTOR; s++) g_written[s] = 1;
}

static uint32_t rd32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static void wr32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }

bool ios_t18_is_firmware(const uint8_t *rom, uint32_t len) {
    return rom && len == IOS_T18_FLASH_SIZE && rom[0] == 'S' && rom[1] == 'P' && rom[2] == 'I' && rom[3] == 'I'
        && rd32(rom + 4) == 0x2000000Cu;
}

/* The game's Param block in SRAM (call flags, Gotchi Points). Same search as
 * Paramix Studio's t18Param: the literal pool of DispYobidashiIconInit holds
 * it right before the address of that function's debug text. */
static uint32_t find_param(const uint8_t *fw, uint32_t len) {
    static const char pat[] = "DispYobidashiIconInit() pYobi";
    const uint32_t n = sizeof pat - 1;
    uint32_t s = 0; bool found = false;
    for (uint32_t i = 0; i + n <= len; i++) {
        if (fw[i] == (uint8_t)pat[0] && memcmp(fw + i, pat, n) == 0) { s = i; found = true; break; }
    }
    if (!found) return 0;
    while (s > 0 && fw[s - 1] != 0) s--;
    uint32_t addr = 0x20000000u + s;
    for (uint32_t p = 4; p + 4 <= len; p++) {
        if (rd32(fw + p) == addr) {
            uint32_t v = rd32(fw + p - 4);
            return (v >= 0xF800C000u && v <= 0xF800F000u) ? v : 0;
        }
    }
    return 0;
}

bool ios_t18_start(const uint8_t *rom, uint32_t len) {
    if (!ios_t18_is_firmware(rom, len)) return false;
    ios_t18_stop();
    g_flash = malloc(IOS_T18_FLASH_SIZE);
    t18_sram = calloc(1, T18_SRAM_SIZE);
    g_t = calloc(1, tg18_struct_size());
    if (!g_flash || !t18_sram || !g_t) { ios_t18_stop(); return false; }
    s_live = s_capture = false;
    memcpy(g_flash, rom, IOS_T18_FLASH_SIZE);
    memset(g_written, 0, sizeof g_written);
    for (int i = 0; i < 128; i++) t18_fblk[i] = g_flash + ((uint32_t)i << 16);
    tg18_init(g_t, g_flash, IOS_T18_FLASH_SIZE);
    tg18_set_param_addr(g_t, find_param(g_flash, IOS_T18_FLASH_SIZE));
    return true;
}

void ios_t18_stop(void) {
    free(g_t); g_t = NULL;
    free(t18_sram); t18_sram = NULL;
    free(g_flash); g_flash = NULL;
    for (int i = 0; i < 128; i++) t18_fblk[i] = NULL;
}

bool ios_t18_running(void) { return g_t != NULL; }

/* ---- sound: the buzzer's pitch sampled every millisecond of emulated time,
 * rendered as a square wave into a ring the audio thread pulls from (same
 * scheme as the T7 port's t7_snd_pull). Menu beeps last ~32 ms and melody
 * notes ~40 ms, too short for a once-per-frame poll to follow cleanly. ---- */
#define RING 16384u
static int16_t s_ring[RING];
static volatile uint32_t s_w, s_r;   /* writer: stepping thread; reader: audio thread */
static uint32_t s_rfrac;
static int32_t s_last;
static bool s_live, s_capture;
static uint32_t s_rate = 48000, s_frac_us;   /* samples owed, in sample-microseconds */
static double s_phase;
static uint32_t s_last_hz, s_quiet_ms;
#define AMP 26000

static void snd_render(uint32_t hz, uint32_t us) {
    s_frac_us += us * s_rate;
    uint32_t n = s_frac_us / 1000000u; s_frac_us %= 1000000u;
    uint32_t w = s_w;
    for (uint32_t i = 0; i < n; i++) {
        int16_t v = 0;
        if (hz) { v = s_phase < 0.5 ? AMP : -AMP; s_phase += (double)hz / s_rate; if (s_phase >= 1.0) s_phase -= 1.0; }
        s_ring[w & (RING - 1)] = v; w++;
    }
    __atomic_store_n(&s_w, w, __ATOMIC_RELEASE);
}

void ios_t18_sound_live(bool on, uint32_t sample_rate) {
    s_live = on; s_capture = on;
    if (sample_rate) s_rate = sample_rate;
    s_frac_us = 0; s_phase = 0; s_last_hz = 0; s_quiet_ms = 1000;
}
void ios_t18_sound_capture(bool on) { s_capture = on && s_live; }

uint32_t ios_t18_sound_pull(int16_t *out, uint32_t n, uint32_t target) {
    uint32_t w = __atomic_load_n(&s_w, __ATOMIC_ACQUIRE), have = w - s_r, step = 65536;
    if (target) {
        uint32_t hard = RING * 3 / 4;
        if (have > hard) { s_r = w - target; have = target; s_rfrac = 0; }
        if      (have < target / 2)     step = 60293;
        else if (have < target * 3 / 4) step = 62915;
        else if (have > target * 3)     step = 66847;
    }
    uint32_t real = 0;
    for (uint32_t i = 0; i < n; i++) {
        have = w - s_r;
        if (have >= 2) {
            int32_t a = s_ring[s_r & (RING - 1)], b = s_ring[(s_r + 1) & (RING - 1)];
            int32_t v = a + (int32_t)(((int64_t)(b - a) * s_rfrac) >> 16);
            out[i] = (int16_t)v; s_last = v;
            s_rfrac += step; s_r += s_rfrac >> 16; s_rfrac &= 0xFFFF;
            real++;
        } else {
            s_last = (s_last * 255) / 256;
            out[i] = (int16_t)s_last;
        }
    }
    return real;
}
void ios_t18_sound_skip_to(uint32_t keep) {
    uint32_t w = __atomic_load_n(&s_w, __ATOMIC_ACQUIRE);
    if (w - s_r > keep) { s_r = w - keep; s_rfrac = 0; }
}
bool ios_t18_sound_busy(void) { return s_live && s_quiet_ms < 200; }

void ios_t18_run_us(uint32_t us) {
    if (!g_t) return;
    if (!s_live) { tg18_run_us(g_t, us); return; }
    while (us) {
        uint32_t step = us < 1000 ? us : 1000;
        tg18_run_us(g_t, step);
        us -= step;
        uint32_t hz = tg18_tone_hz(g_t);
        if (hz < 20 || hz > 20000) hz = 0;
        if (hz) s_quiet_ms = 0; else if (s_quiet_ms < 100000) s_quiet_ms++;
        s_last_hz = hz;
        if (s_capture) snd_render(hz, step);
    }
}
void ios_t18_set_buttons(int mask) { if (g_t) tg18_set_buttons(g_t, mask & 7); }

uint32_t ios_t18_get_frame(uint16_t *out) {
    if (!g_t) return 0;
    if (out) memcpy(out, tg18_picture(g_t), IOS_T18_LCD_WIDTH * IOS_T18_LCD_HEIGHT * 2);
    return (uint32_t)tg18_picture_count(g_t);
}
int ios_t18_backlight(void) { return g_t ? tg18_backlight(g_t) : 0; }
uint32_t ios_t18_tone_hz(void) { return g_t ? tg18_tone_hz(g_t) : 0; }
bool ios_t18_attention(void) { return g_t && tg18_attention(g_t); }
bool ios_t18_power(void) { return g_t && tg18_power(g_t); }

void ios_t18_set_time(int y, int mo, int d, int h, int mi, int s) { if (g_t) tg18_set_time(g_t, y, mo, d, h, mi, s); }
void ios_t18_get_time(int out6[6]) {
    if (g_t) tg18_get_time(g_t, out6);
    else memset(out6, 0, 6 * sizeof(int));
}

int ios_t18_get_points(void) { return g_t ? tg18_param_get16(g_t, 0x20) : -1; }
bool ios_t18_set_points(int value) {
    if (!g_t) return false;
    if (value < 0) value = 0;
    if (value > 65535) value = 65535;
    return tg18_param_set16(g_t, 0x20, value) == 0;
}

/* state: magic, core state size, core state, SRAM */
uint32_t ios_t18_save_state(uint8_t *buf, uint32_t len) {
    if (!g_t) return 0;
    uint32_t core = tg18_state_size(g_t), need = 8 + core + T18_SRAM_SIZE;
    if (!buf) return need;
    if (len < need) return 0;
    wr32(buf, STATE_MAGIC); wr32(buf + 4, core);
    if (tg18_save_state(g_t, buf + 8, core) < 0) return 0;
    memcpy(buf + 8 + core, t18_sram, T18_SRAM_SIZE);
    return need;
}

bool ios_t18_load_state(const uint8_t *buf, uint32_t len) {
    if (!g_t || !buf || len < 8 || rd32(buf) != STATE_MAGIC) return false;
    uint32_t core = rd32(buf + 4);
    if (core != tg18_state_size(g_t) || len < 8 + core + T18_SRAM_SIZE) return false;
    /* SRAM first: load_state hands the DMA channels back in SRAM */
    memcpy(t18_sram, buf + 8 + core, T18_SRAM_SIZE);
    return tg18_load_state(g_t, buf + 8, core) == 0;
}

/* flash: magic, count, then count x (word, then 4 KB unless erased). The
 * word is the sector number, with bit 31 set for a sector that is all 0xFF
 * (erased): the first start formats about 2.6 MB of save area, almost all
 * of it left empty. */
#define ERASED_BIT 0x80000000u
static bool sector_erased(uint32_t s) {
    const uint8_t *p = g_flash + s * SECTOR;
    for (uint32_t i = 0; i < SECTOR; i++) if (p[i] != 0xFF) return false;
    return true;
}
uint32_t ios_t18_flash_save(uint8_t *buf, uint32_t len) {
    if (!g_flash) return 0;
    uint32_t count = 0, need = 8;
    for (uint32_t s = 0; s < SECTORS; s++) {
        if (!g_written[s]) continue;
        count++; need += 4 + (sector_erased(s) ? 0 : SECTOR);
    }
    if (!buf) return need;
    if (len < need) return 0;
    wr32(buf, FLASH_MAGIC); wr32(buf + 4, count);
    uint8_t *p = buf + 8;
    for (uint32_t s = 0; s < SECTORS; s++) {
        if (!g_written[s]) continue;
        if (sector_erased(s)) { wr32(p, s | ERASED_BIT); p += 4; continue; }
        wr32(p, s); memcpy(p + 4, g_flash + s * SECTOR, SECTOR); p += 4 + SECTOR;
    }
    return need;
}

bool ios_t18_flash_load(const uint8_t *buf, uint32_t len) {
    if (!g_flash || !buf || len < 8 || rd32(buf) != FLASH_MAGIC) return false;
    uint32_t count = rd32(buf + 4);
    const uint8_t *p = buf + 8, *end = buf + len;
    for (uint32_t i = 0; i < count; i++) {
        if (end - p < 4) return false;
        uint32_t w = rd32(p), s = w & ~ERASED_BIT;
        if (s >= SECTORS) return false;
        if (w & ERASED_BIT) { memset(g_flash + s * SECTOR, 0xFF, SECTOR); p += 4; }
        else {
            if (end - p < 4 + (long)SECTOR) return false;
            memcpy(g_flash + s * SECTOR, p + 4, SECTOR); p += 4 + SECTOR;
        }
        g_written[s] = 1;
    }
    return true;
}
