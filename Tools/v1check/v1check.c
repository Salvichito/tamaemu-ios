/*
 * v1check: headless health check for one first-gen (TamaLib) ROM.
 *
 * Runs the ROM through the app's own C core (Packages/TamaLibCore) with no
 * app around it and prints a Markdown section: what was checked, PASS /
 * WARN / FAIL per check, and ASCII screen snapshots to eyeball.
 *
 * Usage: v1check <rom.bin> <toy-id> [start-up steps, overriding the table]
 * Built and run for every ROM by Tools/v1check/run.sh.
 *
 * Toy facts (start-up steps, expected hatch time) come from each toy's
 * Japanese manual in ~/Documents/Tamagotchi/research/vintage-care-icons, or
 * from measurements where no manual is at hand (marked as such).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdarg.h>
#include "ios_hal.h"

typedef struct {
	const char *id;
	const char *name;
	int model;            /* IOS_HAL_MODEL_* */
	const char *recipe;   /* start-up presses, see run_recipe() */
	double hatch_min_s;   /* expected hatch window after the recipe; 0 = no egg check */
	double hatch_max_s;
	const char *hatch_source;
	int icons;            /* 1 = has the 8 screen icons, A steps through them */
	int a_btn;            /* pin that steps the menu */
	int back_btn;         /* pin that leaves the clock screen */
} toy_t;

/* Recipes: letters press a button (A=0, B=1, C=2 pins); digits after 'w'
 * wait that many ms; h<ms> sets how long later presses are held; X leaves the clock screen (presses the toy's back
 * button until the clock is gone -- after confirming the time, most of these
 * toys keep showing the clock, and how soon "back" works varies). */
static const toy_t TOYS[] = {
	{ "p1",        "P1",                     IOS_HAL_MODEL_P1, "B A C X", 240, 390, "P1 manual: about 5 min", 1, 0, 1 },
	{ "p1j",       "P1 (Japanese)",          IOS_HAL_MODEL_P1, "B A C X", 240, 390, "P1 manual: about 5 min", 1, 0, 1 },
	{ "p2",        "P2",                     IOS_HAL_MODEL_P1, "B A C X", 240, 390, "assumed same as P1", 1, 0, 1 },
	{ "angel",     "Angel",                  IOS_HAL_MODEL_P1, "B A C X", 240, 390, "no manual; assumed same as P1", 1, 0, 1 },
	{ "morino",    "Mori de Hakken (Morino)", IOS_HAL_MODEL_P1, "B A C X B w1000 B", 120, 300, "manual: about 3 min", 1, 0, 1 },
	{ "umino",     "Umi de Hakken (Umino)",  IOS_HAL_MODEL_ICON_PER_SEGMENT, "B A C w3000 B", 0, 0, "no manual at hand", 1, 0, 1 },
	{ "genjintch", "Genjintch",              IOS_HAL_MODEL_GENJINTCH, "B A C w2000 B", 0, 0, "no manual at hand", 1, 0, 1 },
	{ "tamaotch",  "Tamaotch",               IOS_HAL_MODEL_TAMAOTCH, "h500 B w1500 A w1500 C w3000 A", 240, 420, "manual: about 5 min after choosing the egg", 1, 0, 1 },
	{ "mothra",    "Mothra",                 IOS_HAL_MODEL_MOTHRA, "B A C X", 240, 420, "manual: about 5 min", 1, 0, 1 },
	{ "yasashii",  "Yasashii",               IOS_HAL_MODEL_YASASHII, "B B A X", 240, 390, "manual: about 5 min", 0, 1, 2 },
	{ "digimon-v1", "Digimon V1",            IOS_HAL_MODEL_DIGIMON, "", 0, 0, "different toy, no egg check", 0, 0, 1 },
	{ "digimon-v2", "Digimon V2",            IOS_HAL_MODEL_DIGIMON, "", 0, 0, "different toy, no egg check", 0, 0, 1 },
	{ "digimon-v3", "Digimon V3",            IOS_HAL_MODEL_DIGIMON, "", 0, 0, "different toy, no egg check", 0, 0, 1 },
};

static int fails, warns;
static void result(const char *what, int level, const char *fmt, ...)
{
	static const char *tag[] = { "PASS", "WARN", "FAIL", "INFO" };
	char msg[512];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(msg, sizeof msg, fmt, ap);
	va_end(ap);
	if (level == 1) warns++;
	if (level == 2) fails++;
	printf("| %s | **%s** | %s |\n", what, tag[level], msg);
}

static void run_ms(uint32_t ms)
{
	uint32_t s = ios_hal_elapsed_us();
	while ((uint32_t)(ios_hal_elapsed_us() - s) < ms * 1000u) {
		ios_hal_step_many(100);
	}
}

static void press(int pin, int hold_ms, int gap_ms)
{
	ios_hal_set_button(pin, true);
	run_ms(hold_ms);
	ios_hal_set_button(pin, false);
	run_ms(gap_ms);
}

/* The clock screen's "AM"/"SET" mark: a solid block at the bottom left
 * (rows 8-15, columns 2-8) that no egg screen lights this much. */
static int on_clock_screen(void)
{
	int n = 0;
	for (int y = 8; y < 16; y++)
		for (int x = 2; x <= 8; x++)
			n += ios_hal_get_pixel(x, y);
	return n >= 18;
}

static void run_recipe(const char *r, int back_btn)
{
	int hold = 200;
	for (const char *p = r; *p; p++) {
		if (*p == 'h') {                       /* h<ms>: hold later presses this long */
			hold = atoi(p + 1);
			while (p[1] >= '0' && p[1] <= '9') p++;
			continue;
		}
		if (*p == 'X') {
			for (int i = 0; i < 4 && on_clock_screen(); i++) {
				run_ms(1500);
				if (on_clock_screen()) press(back_btn, 200, 1000);
			}
		} else if (*p == 'A' || *p == 'B' || *p == 'C') {
			press(*p - 'A', hold, 700);  /* screens can take >0.4 s to switch */
		} else if (*p == 'w') {
			run_ms((uint32_t)atoi(p + 1));
			while (p[1] >= '0' && p[1] <= '9') p++;
		}
	}
}

static unsigned frame_hash(void)
{
	unsigned h = 2166136261u;
	for (int y = 0; y < 16; y++)
		for (int x = 0; x < 32; x++)
			h = (h ^ ios_hal_get_pixel(x, y)) * 16777619u;
	return h;
}

static int lit_pixels(void)
{
	int n = 0;
	for (int y = 0; y < 16; y++)
		for (int x = 0; x < 32; x++)
			n += ios_hal_get_pixel(x, y);
	return n;
}

static uint8_t icons(void)
{
	uint8_t bits[64], ic;
	ios_hal_get_frame(bits, &ic);
	return ic;
}

static int popcount8(uint8_t v)
{
	int n = 0;
	while (v) { n += v & 1; v >>= 1; }
	return n;
}

static void snapshot(const char *title)
{
	uint8_t ic = icons(), lamps = ios_hal_get_lamps();
	printf("\n`%s` (icons ", title);
	for (int i = 0; i < 8; i++) putchar(ic >> i & 1 ? '0' + i : '.');
	if (lamps) {
		printf(", lamps ");
		for (int i = 0; i < 6; i++) putchar(lamps >> i & 1 ? "MHATLS"[i] : '.');
	}
	printf(")\n```\n");
	for (int y = 0; y < 16; y++) {
		for (int x = 0; x < 32; x++) putchar(ios_hal_get_pixel(x, y) ? '#' : '.');
		putchar('\n');
	}
	printf("```\n");
}

static double now_s(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

/* Waits for the screen to leave the egg: the frames seen over a quiet
 * stretch right after the recipe count as "egg"; the hatch is the first
 * sample of a run of 6 (3 s) that are all outside that set. Returns seconds
 * after the recipe, or -1. */
static double wait_for_hatch(double limit_s)
{
	enum { MAXF = 32 };
	unsigned egg[MAXF];
	int negg = 0;
	uint32_t t0 = ios_hal_elapsed_us();
	run_ms(2000);
	for (int i = 0; i < 60; i++) {          /* 30 s of egg frames */
		unsigned h = frame_hash();
		int seen = 0;
		for (int k = 0; k < negg; k++) seen |= egg[k] == h;
		if (!seen && negg < MAXF) egg[negg++] = h;
		run_ms(500);
	}
	int run = 0;
	double first = -1;
	while ((ios_hal_elapsed_us() - t0) / 1e6 < limit_s) {
		run_ms(500);
		unsigned h = frame_hash();
		int in_egg = 0;
		for (int k = 0; k < negg; k++) in_egg |= egg[k] == h;
		if (icons()) {
			/* a lit menu icon means it has hatched (eggs light none) */
			return run ? first : (ios_hal_elapsed_us() - t0) / 1e6;
		}
		if (in_egg) { run = 0; first = -1; continue; }
		if (run == 0) first = (ios_hal_elapsed_us() - t0) / 1e6 - 0.5;
		if (++run >= 40) return first;      /* 20 s away from the egg */
	}
	return -1;
}

int main(int argc, char **argv)
{
	if (argc < 3) {
		fprintf(stderr, "usage: v1check <rom.bin> <toy-id>\n");
		return 2;
	}
	const toy_t *toy = NULL;
	for (size_t i = 0; i < sizeof TOYS / sizeof TOYS[0]; i++)
		if (!strcmp(TOYS[i].id, argv[2])) toy = &TOYS[i];
	if (!toy) { fprintf(stderr, "unknown toy %s\n", argv[2]); return 2; }

	FILE *f = fopen(argv[1], "rb");
	if (!f) { printf("## %s\n\nROM not found: %s\n", toy->name, argv[1]); return 1; }
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	rewind(f);
	unsigned char *d = malloc(n);
	fread(d, 1, n, f);
	fclose(f);
	uint16_t *w = malloc(n);
	for (long i = 0; i < n / 2; i++) w[i] = (uint16_t)(d[2 * i] << 8 | d[2 * i + 1]);

	printf("## %s\n\n| Check | Result | Detail |\n|---|---|---|\n", toy->name);

	/* 1. Real-time pace: 3 real seconds, paced like the live app. Its own
	 *    run, so the start-up below begins right after power-on: some toys
	 *    (Angel) change screen a few seconds in and stop taking the clock
	 *    button there. */
	ios_hal_start(w, (uint32_t)(n / 2), toy->model);
	{
		double t0 = now_s();
		uint32_t e0 = ios_hal_elapsed_us();
		while (now_s() - t0 < 3.0) ios_hal_step();
		double ratio = (ios_hal_elapsed_us() - e0) / 1e6 / (now_s() - t0);
		result("Runs at real speed", ratio > 0.98 && ratio < 1.02 ? 0 : 2,
		       "%.3f emulated seconds per real second", ratio);
	}
	ios_hal_stop();

	/* 2. Boot. */
	ios_hal_start(w, (uint32_t)(n / 2), toy->model);
	ios_hal_set_fast_forward(true);
	run_ms(2000);
	{
		int lit = lit_pixels();
		result("Boots and draws", lit > 4 && lit < 400 ? 0 : 2, "%d of 512 pixels lit after 2 s", lit);
	}
	snapshot("after boot");

	/* 3. Start-up and hatch. */
	double hatch = -2;
	const char *recipe = argc > 3 ? argv[3] : toy->recipe;   /* override, for finding steps */
	run_recipe(recipe, toy->back_btn);
	if (recipe[0]) {
		run_ms(2000);
		snapshot("right after start-up steps (should be the egg)");
		if (on_clock_screen())   /* P1-style clock layout only */
			result("Start-up steps reach the egg", 2, "still on the clock screen; the check's steps for this toy are wrong");
	}
	if (toy->hatch_max_s > 0) {
		hatch = wait_for_hatch(toy->hatch_max_s * 2 + 60);
		if (hatch < 0) {
			result("Egg hatches on time", 2, "no hatch within %.0f min (%s)", (toy->hatch_max_s * 2 + 60) / 60, toy->hatch_source);
		} else {
			int ok = hatch >= toy->hatch_min_s && hatch <= toy->hatch_max_s;
			result("Egg hatches on time", ok ? 0 : 2, "%.1f min after clock set; expected %.1f-%.1f (%s)",
			       hatch / 60, toy->hatch_min_s / 60, toy->hatch_max_s / 60, toy->hatch_source);
		}
	} else if (recipe[0]) {
		hatch = wait_for_hatch(15 * 60);
		result("Egg hatches on time", 3, hatch < 0 ? "no hatch seen within 15 min (%s)" : "%s; screen changed %.1f min after clock set",
		       hatch < 0 ? toy->hatch_source : toy->hatch_source, hatch / 60);
	}
	run_ms(60000);
	snapshot("1 min after hatch (or start-up)");

	/* 4. Menu: A steps one icon at a time; short presses register. */
	if (toy->icons) {
		int changes = 0, multi = 0;
		uint8_t seq[10];
		uint8_t prev = icons() & 0x7F;
		for (int i = 0; i < 9; i++) {
			press(toy->a_btn, 200, 500);
			uint8_t ic = icons() & 0x7F;
			seq[i] = ic;
			if (ic != prev) changes++;
			if (popcount8(ic) > 1) multi++;
			prev = ic;
		}
		char s[128] = "", *p = s;
		for (int i = 0; i < 9; i++) {
			int k = -1;
			for (int b = 0; b < 7; b++) if (seq[i] >> b & 1) k = b;
			p += sprintf(p, "%s%s", i ? " " : "", popcount8(seq[i]) > 1 ? "*" : k < 0 ? "-" : (char[]){ (char)('0' + k), 0 });
		}
		result("A steps through icons", changes >= 6 && !multi ? 0 : 2,
		       "%d of 9 presses changed the icon; lights after each: %s%s", changes, s,
		       multi ? " (* = several lit at once)" : "");
		snapshot("menu after 9 A presses");
		for (int i = 0; i < 3; i++) press(2, 200, 500);   /* back out */

		int short_changes = 0;
		prev = icons() & 0x7F;
		for (int i = 0; i < 6; i++) {
			press(toy->a_btn, 80, 400);
			uint8_t ic = icons() & 0x7F;
			if (ic != prev) short_changes++;
			prev = ic;
		}
		/* Tamaotch needs ~0.15 s presses (and drops some 0.2 s ones at
		 * certain moments); the app holds its taps 0.2 s, spaced 0.3 s. */
		int tama = !strcmp(toy->id, "tamaotch");
		result("Short presses (0.08 s) register", short_changes >= 5 ? 0 : (short_changes >= 3 || tama) ? 1 : 2,
		       "%d of 6%s", short_changes, tama ? " (known: needs ~0.15 s; the app holds its taps 0.2 s)" : "");
		for (int i = 0; i < 3; i++) press(2, 200, 500);
	}

	/* 5. Calls in an hour left alone (the app's own rule: attention icon,
	 *    or a lit Yasashii lamp within the last 5 s). */
	{
		int on = 0, edges = 0;
		double last_lit = -100;
		uint32_t t0 = ios_hal_elapsed_us();
		while ((ios_hal_elapsed_us() - t0) / 1e6 < 3600) {
			run_ms(100);
			double t = (ios_hal_elapsed_us() - t0) / 1e6;
			int lamp = ios_hal_get_lamps() != 0;
			if (lamp) last_lit = t;
			int now_on = (icons() & 0x80) || lamp || t - last_lit < 5.0;
			if (now_on && !on) edges++;
			on = now_on;
		}
		result("Calls in an hour, left alone", edges <= 30 ? 0 : 1, "%d", edges);
		int lit = lit_pixels();
		result("Still drawing after the hour", lit > 4 && lit < 400 ? 0 : 1, "%d pixels lit", lit);
		snapshot("after an hour left alone");
	}

	/* 6. Save and resume give the same result as carrying on. */
	{
		uint32_t sz = ios_hal_state_size();
		uint8_t *buf = malloc(sz);
		uint32_t wr = ios_hal_save_state(buf, sz);
		run_ms(5000);
		unsigned straight = frame_hash();
		uint8_t straight_ic = icons();
		ios_hal_stop();
		ios_hal_start(w, (uint32_t)(n / 2), toy->model);
		int ok = wr > 0 && ios_hal_load_state(buf, wr);
		ios_hal_set_fast_forward(true);
		run_ms(5000);
		int same = ok && frame_hash() == straight && icons() == straight_ic;
		result("Save and resume match carrying on", same ? 0 : 1,
		       ok ? (same ? "same screen 5 s later" : "screens differ 5 s later") : "save or load failed");
		free(buf);
	}
	ios_hal_stop();

	printf("\nSummary for %s: %d fail, %d warn\n\n", toy->name, fails, warns);
	return fails ? 1 : 0;
}
