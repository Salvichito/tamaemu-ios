# Tomomix Animations & Art List — draft 1

Every moment in the game that moves, what it shows, how long it lasts, and the drawings it needs. This doubles as the **art checklist**: each line in §6 is one export from Figma.

Rules live in [Rulebook.md](Rulebook.md). § numbers below point there.

## 1. How animations are built

Each animation mixes two ingredients:

| Ingredient | Who makes it | Examples |
|---|---|---|
| **Poses**: drawings of the character | You, in Figma | eating with mouth open, sleeping, happy |
| **Motion**: moving those drawings | The app | bounce, wander, shake, squash, flip, fade, glow |

A "happy" moment is then one happy pose plus a bounce from the app, rather than 8 hand-drawn frames. When a moment needs more life, add more poses. The app plays them in order like a flipbook.

**Fallbacks:** if a pose isn't drawn yet, the app uses the fallback listed in §3. You can ship a character with only the core poses and add the rest later.

**Tap to skip (§2 of the rulebook):** every animation marked *skippable* below ends immediately when the screen is tapped.

## 2. Drawing conventions

| Topic | Convention |
|---|---|
| Artboard | **The same square size for every character pose**, e.g. 512 × 512. A Baby is small inside it and an adult is big. That keeps sizes consistent between stages without the app scaling anything. |
| Feet | Every pose stands on the **same baseline: feet at y = 442** of 512, centered horizontally. Switching poses then never makes the character jump. |
| Background | Transparent. |
| Facing | Draw characters facing **front or left**. The app mirrors for the right side. If a character isn't symmetric (a bow on one side, say), add an explicit `look-right` pose. |
| Format | **SVG** (or PDF) export, so the art stays sharp at any size. PNG at 3× also works. |
| Names | `tomo-<character>-<pose>-<n>`, all lowercase, e.g. `tomo-1a-eat-2`. Leave out `-<n>` when there's only one frame. Character names are in §6. |

## 3. Character poses

Every living character (Baby through all adults) uses this set. **Core** poses are needed before a character can appear in the game; the rest fall back.

| Pose | Frames | Used for | Core? | If not drawn, uses |
|---|---|---|---|---|
| `idle` | 1–2 | Standing around; the app makes it wander | ✅ (`idle-1`) | `idle-2` → `idle-1` |
| `eat` | 2 | Mouth open / mouth closed, repeated 2 or 4 bites (§14) | ✅ | — |
| `refuse` | 1 | Turning away food or a game; also mad, angry, upset | ✅ | — |
| `happy` | 1 | After a snack, a good game, a cure, a clean (app bounces it) | ✅ | — |
| `sick` | 1 | Sick (app adds the skull); also sad | ✅ | — |
| `look` | 1 | Looking to its left: while walking left (glancing back at the player about 1 step in 4), and in the Follow Me game | ✅ | — |
| `look-right` | 1 | Looking to its right: while walking right, and in the Follow Me game | ✅ | `look`, flipped |
| `sleep` | 1 | Asleep (app adds Zzz) | | `eat-1` |
| `blink` | 1 | Random blinks while idle | | `idle-1` |
| `sad` | 1 | A failed game, an empty meter | | `sick` |
| `call` | 1 | Calling for attention | | `sad` → `sick` |

**Per character: 7 core drawings** (`idle-1`, `eat-1`, `eat-2`, `refuse`, `happy`, `sick`, `look`), plus `look-right` for characters that shouldn't be flipped. Everything else is optional.

The character is **never flipped while walking**, since some characters aren't symmetric. Only `look` is flipped, and only when there's no `look-right`.

## 4. Moments and their timing

| Moment | What happens | Length | Skippable |
|---|---|---|---|
| Idle | `idle` frames alternate; it **hops** one step every half second (a full second when sick) toward a random spot on the rug, sideways and slightly forward or back, waits, then picks another. No smooth sliding, for a retro feel. When happiness is **above half** it sometimes jumps while waiting: `happy` pose, up for one beat, then a smile on the ground (about every 13 s at 3 hearts, 7 s at 4). | loops | — |
| Tapped | Only when it's doing fine: `happy` pose, a stepped hop right where it stands (up, half way, landed) | 0.6 s | ✅ |
| Meal / snack | Food appears on its left, then `eat` × bites while the food shrinks (§5 props) | ~0.5 s per bite | ✅ |
| Refuse | `refuse` with a side-to-side shake | 1 s | ✅ |
| Happy | `happy` with a bounce, hearts float up | 1.5 s | ✅ |
| Sad | `sad`, a sweat drop | 1.5 s | ✅ |
| Medicine | "Sana sana, culito de rana": the healing frog pops out of the window's lower-right pane in 2 steps (from the left edge outdoors), grows to adult-tomomix size and makes 3 stepped hops over (0.45–1.65 s), turns its back and toots: the cloud glides smoothly out of its back to the right, onto the face (1.8–2.9 s, toot sound) — the tomomix makes its `refuse` face — then hops home. Cured: magic + happy chimes, `happy` hops and sparkles; another dose needed: stays `sick` | 4.2 s | ✅ |
| Clean | The swoosh sweeps across the whole screen (easing in and out); the poop sticks to it as it passes and rides it off the right edge | 1.5 s | ✅ |
| Cleaned up | Only if there was poop: right after the swoosh, it hops for joy a few times (the Happy moment) with the happy chime | 1.5 s | ✅ |
| Poop appears | Poop drops in beside it | 1 s | ✅ |
| Scold | No effect: upset (`refuse`, quick shake, 0–0.7 s), crying (`sad`, smaller shake, to 1.5 s), then it accepts it (`happy` with a hop) | 2.3 s | ✅ |
| Misbehaving | Nothing changes (as on the classic toy): only the attention icon lights up | — | ✅ |
| Scolded for nothing | `sad` face with the confused squiggle (`tomo-confused-1`, `-2`, `-2-1`) turning where the spiral goes | 2 s | ✅ |
| Medicine when not sick | The `refuse` "no", like refusing food | 1 s | ✅ |
| Calling | `call` while the attention icon is lit | loops | — |
| Falling asleep / waking | The light dims, `sleep` with Zzz / the reverse | 1 s | ✅ |
| Sick | `sick` with the skull, while sick | loops | — |
| Follow Me: showing | `look` (mirrored for right) with the direction's beep | 0.55 s each | ❌ gameplay |
| Follow Me: result | `happy` (Perfect/Good/OK) or `sad` (Fail) with a result badge | until tapped | ✅ |
| Evolving | Like the birth: it hops up, the burst (`tomo-evolution`) grows while the screen fades to white, and the new character, happy, appears as the white fades (hop 0–0.6 s, white by 1.5 s, clear by 2.4 s) | 3 s | ✅ |
| Old | Same poses; the app makes it move a little slower | — | — |

## 5. Shared art (not per character)

### Props and effects

| Item | Frames | Used in |
|---|---|---|
| `tomo-meal` | 3: whole, half, crumbs | Meal ✅. Shown at about 44% of the character's size, on its left. Frame 1 is also the food menu choice (drawing only, no words) |
| `tomo-snack` | 3: whole, half, crumbs | Snack ✅ |
| `tomo-poop-small` | 1 | Poop 1–4 (§10) ✅, on four floor spots mirrored left/right (screen 72.96%/27.04% × 80.6%, then 90.4%/9.6% × 73.1%), filling right to left, drawn in front of the tomo and food. One drawing with its smell waves: the import script lifts out each wave (any shape more than ~2× taller than wide) and the app flips each one left-right about once a second, out of step |
| `tomo-poop-big` | 1 | Poop 5–8 (§10) ✅, same as the small one |
| `tomo-swoosh` | 1 | The cleaning wipe: a tall band of stars (481 × 1075), covering the full screen height; each sparkle twinkles on its own ✅ |
| `tomo-healing` | 1 | The healing frog. The import script splits it into `tomo-healing-frog` and `tomo-healing-cloud` (shapes right of x = 295), same 512 canvas |
| `tomo-sick` | 3 | Sick ✅: the scribble ball churns through its 3 drawings (0.22 s each), top-right of its head. While sick it stands still in the middle with its `sick` face |
| `tomo-needy` | 3 | Needs care (calling) ✅: the dizzy spiral turns through its 3 drawings, top-right of its head, following it as it walks. Replaces `tomo-call` |
| `tomo-zzz` | 1 | Asleep ✅. One drawing; the import script makes each letter its own layer (in Figma layer order) and the app shows them one after another (0.6 s apart), holds, clears, repeats every 3 s |
| `tomo-heart` | 1 | Happy (floats up) |
| `tomo-sparkle` | 1–2 | Evolving, cured |
| `tomo-thought` | 1 | Thought bubble ✅ when a meter has one step left, top-right of its head with the trailing puffs toward it. Holds `tomo-meal-1` or `tomo-snack-1`, centered in the cloud (y = 112 of 256); wanting both, it blinks between them every 0.8 s |
| `tomo-badge-perfect`, `-good`, `-ok`, `-fail` | 1 each | Follow Me results |

### Scenes

| Item | Frames | Used in |
|---|---|---|
| `tomo-room` | 1 | The whole screen: a 596 × 596 square room, edge to edge. The icons float on top. The window is cut out so the sky shows through. The tomomix stands on the rug (feet at y = 415, the middle of the rug) and walks across it. |
| `tomo-outdoors` | 1 | Outdoors (B button): the meadow, same 596 square, with a transparent sky so the time-of-day sky shows behind it. Pale on purpose so the tomomix pops. It lines up with the room, so the tomomix stands exactly where it does indoors (feet at y = 415). Poop stays in the room and isn't shown outside. At night the top row of icons turns light over the dark sky. |
| `tomo-outdoors-birth` | 1 | Birth steps 3–4: the same meadow in stronger colors, over the night sky. The fallen star rests at y = 367, just below the top of the grass. |
| `tomo-sky-morning`, `-day`, `-evening`, `-night` | 1 each | Behind the room's window and the whole outdoors. Same square size. Follows the phone's clock (morning 6–10, day 10–17, evening 17–20, night otherwise); night while the light is off. Until drawn, soft gradients stand in; night uses the starry night below. |
| `tomo-starrynight` | 1 | The night sky: birth, ending, and the night window/outdoors. The import script reads each star (position, size, color) and the background color out of it, and the app fades every star in and out on its own slow pace (5–11 s). Just add or move dots in Figma and re-export. |
| `tomo-twinkle` | 2 | Small stars twinkling in the night sky |
| `tomo-shootingstar` | 1 | Exported as a 596 square on the night color. The import script cuts it into **`tomo-shooting-star`** (star + curved trail, no background) and **`tomo-star-fallen`** (the 4-point star alone). The shooting star crosses the sky (flipped for stars going left), then falls head-first onto the meadow with its trail above it. The star alone waits at the top during "Your name?" and pulses on the grass |
| `tomo-ground` | 1 | Not needed any more: only a fallback if `tomo-outdoors-birth` is missing |
| `tomo-burst` | 1–2 | Birth step 5: the burst of light |
| `tomo-star-fixed` | 1–2 | Ending: the fixed star (the app twinkles it; the departed character is its own `idle-1`, faded) |

### Birth and ending timing

| Step | Length | Skippable |
|---|---|---|
| 1. Night sky with shooting stars | Until the player catches one (one passes every 3.2 s, each crossing in 1.6 s) | — |
| 2. Caught star glides to the top, "Your name?" | 0.6 s glide, then waits for the answer (first time only) | — |
| 3. Close-up: falls to the ground | 1.5 s | ✅ |
| 4. Pulses, slow to fast | **30 s** (rulebook §3) | ❌ real wait |
| 5. Burst, Baby appears | 1.5 s | ✅ |
| Ending: tomomix fades into the fixed star | 3 s, then stays | ✅ (the transition only) |

### Interface

| Item | Notes |
|---|---|
| 8 care icons ✅ | `01-food.svg` … `08-attention.svg` in the assets folder (one color, 256 square). The import script makes them `tomo-icon-*` for Tomomix and the P1/P2 screen's `P1Icon*` defaults, cropped to the middle 128. The app tints them (dim/lit, dark/light). |
| Status icons: `tomo-meter-hunger` (stomach), `tomo-meter-happy` (heart or smiley), `tomo-meter-discipline` (brain) | §15 |
| Game arrows: `tomo-arrow` ✅ | Drawn pointing left; mirrored for the right side. |
| Light menu ✅: `tomo-light-on`, `tomo-light-off` (full color) — no words | Food choices reuse `tomo-meal` and `tomo-snack`. |

## 6. Checklist

Character names for file names: `baby`, `child-good`, `child-bad`, `teen-excellent`, `teen-good`, `teen-bad`, `1a`…`1d`, `2a`…`2d`, `3a`…`3d`.

**Core poses** (✅ needed to appear in the game)

| Character | idle-1 | eat ×2 | refuse | happy | sick | look | look-right |
|---|---|---|---|---|---|---|---|
| baby | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| child-good | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| child-bad | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| teen-excellent | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| teen-good | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| teen-bad | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| 1a · 1b · 1c · 1d | ☐☐☐☐ | ☐☐☐☐ | ☐☐☐☐ | ☐☐☐☐ | ☐☐☐☐ | ☐☐☐☐ | ☐☐☐☐ |
| 2a · 2b · 2c · 2d | ☐☐☐☐ | ☐☐☐☐ | ☐☐☐☐ | ☐☐☐☐ | ☐☐☐☐ | ☐☐☐☐ | ☐☐☐☐ |
| 3a · 3b · 3c · 3d | ☐☐☐☐ | ☐☐☐☐ | ☐☐☐☐ | ☐☐☐☐ | ☐☐☐☐ | ☐☐☐☐ | ☐☐☐☐ |

**Optional poses:** `idle-2`, `sleep`, `blink`, `sad`, `call`, `pout`, `scolded` (see §3 for what each falls back to).

**Totals:** 17 characters × 8 drawings (7 core + `look-right`) = **136 drawings**. Plus about 40 shared items in §5.

## 7. Suggested order

1. **Baby, complete** (core + extras), plus the meal, snack, poop and Zzz props. This is the test run of the whole pipeline from Figma into the app.
2. **The birth scene** (§5), since it's the first thing every player sees.
3. **Children and teens** (5 characters).
4. **Adults**, one tier at a time.
5. Interface icons, last: the placeholders work fine in the meantime.


## Chimes

Placeholder square-wave sounds (the app's own synth), each easy to retune:

| Chime | When |
|---|---|
| Happy (ding-ding-diiing, rising) | After cleaning poop, a perfect game (with happy hops), and the hop after a cure |
| Okay (two plain notes) | A game that won some happiness but wasn't perfect (it just smiles) |
| Sad (wah-wah-wahhh, falling) | A failed game (no happiness won) |
| Scary (low dun-dun-dunnn with a wobble) | Scolding |
| Farewell (the sad chime, slower and lower) | Its ending |
| Magic (quick sparkling run up) | Just after the frog's toot, when it cures (then the happy chime) |
| Toot (low wobbly pfrrrt) | The healing frog's toot |

## Status screen

Name big at the top center; three meters with your icons (`tomo-meter-hunger`, `-happy`, `-discipline`, 90 square); weight and age together at the bottom center ("14 kg, 3 years old"). Hunger and happiness steps each keep their own color, left to right: red `#EC4646`, orange `#FFA322`, yellow `#FFEA60`, green `#7BC188` (a full bar shows all four). Discipline (10 steps) is always `#5989A3`.
