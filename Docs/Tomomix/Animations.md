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
| Feet | Every pose stands on the **same baseline**, centered horizontally. Switching poses then never makes the character jump. |
| Background | Transparent. |
| Facing | Draw characters facing **front or left**. The app mirrors for the right side. If a character isn't symmetric (a bow on one side, say), add an explicit `look-right` pose. |
| Format | **SVG** (or PDF) export, so the art stays sharp at any size. PNG at 3× also works. |
| Names | `tomo-<character>-<pose>-<n>`, all lowercase, e.g. `tomo-1a-eat-2`. Leave out `-<n>` when there's only one frame. Character names are in §6. |

## 3. Character poses

Every living character (Baby through all adults) uses this set. **Core** poses are needed before a character can appear in the game; the rest fall back.

| Pose | Frames | Used for | Core? | Fallback |
|---|---|---|---|---|
| `idle` | 2 | Standing around: the app alternates them and makes it wander | ✅ | — |
| `blink` | 1 | Random blinks while idle | | `idle-1` |
| `eat` | 2 | Mouth open / mouth closed, repeated 2 or 4 bites (§14) | ✅ | — |
| `refuse` | 1 | Turning away food or a game (app shakes it) | ✅ | — |
| `happy` | 1 | After eating a snack, a good game, a cure, a clean (app bounces it) | ✅ | — |
| `sad` | 1 | A failed game, an empty meter | | `refuse` |
| `sleep` | 1 | Asleep (app adds Zzz) | ✅ | — |
| `sick` | 1 | Sick (app adds the skull) | ✅ | — |
| `look` | 1 | Follow Me game: pointing or turning to its left (app mirrors for right) | ✅ | — |
| `call` | 1 | Calling for attention, while the attention icon is lit | | `idle-1` |
| `pout` | 1 | Misbehaving | | `refuse` |
| `scolded` | 1 | Being disciplined | | `sad` |

**Per character: 9 core drawings, 14 with everything.** The Baby never misbehaves, so it doesn't need `pout` or `scolded`.

## 4. Moments and their timing

| Moment | What happens | Length | Skippable |
|---|---|---|---|
| Idle | `idle` frames alternate; it wanders left and right every few seconds | loops | — |
| Meal / snack | Food appears beside it, then `eat` × bites while the food shrinks (§5 props) | ~0.5 s per bite | ✅ |
| Refuse | `refuse` with a side-to-side shake | 1 s | ✅ |
| Happy | `happy` with a bounce, hearts float up | 1.5 s | ✅ |
| Sad | `sad`, a sweat drop | 1.5 s | ✅ |
| Medicine | Medicine prop approaches; `happy` if cured, `sick` if it needs another dose | 1.5 s | ✅ |
| Clean | The cleaning prop sweeps across and takes the poop away | 1.5 s | ✅ |
| Poop appears | Poop drops in beside it | 1 s | ✅ |
| Scold | Scold effect, then `scolded` | 1.5 s | ✅ |
| Misbehaving | `pout` with an angry mark, until disciplined or the 14 minutes pass | loops | — |
| Calling | `call` while the attention icon is lit | loops | — |
| Falling asleep / waking | The light dims, `sleep` with Zzz / the reverse | 1 s | ✅ |
| Sick | `sick` with the skull, while sick | loops | — |
| Follow Me: showing | `look` (mirrored for right) with the direction's beep | 0.55 s each | ❌ gameplay |
| Follow Me: result | `happy` (Perfect/Good/OK) or `sad` (Fail) with a result badge | until tapped | ✅ |
| Evolving | Flash, sparkles circle it, it turns into a silhouette and then the new character | 3 s | ✅ |
| Old | Same poses; the app makes it move a little slower | — | — |

## 5. Shared art (not per character)

### Props and effects

| Item | Frames | Used in |
|---|---|---|
| `tomo-meal` | 3: whole, half, crumbs | Meal |
| `tomo-snack` | 3: whole, half, crumbs | Snack |
| `tomo-poop-small` | 2 (a wiggle) | Poop 1–4 (§10) |
| `tomo-poop-big` | 2 (a wiggle) | Poop 5–8 (§10) |
| `tomo-clean` | 1–2 | The cleaning sweep |
| `tomo-medicine` | 1 | Medicine |
| `tomo-skull` | 1 | Sick marker |
| `tomo-zzz` | 3 (growing) | Asleep |
| `tomo-heart` | 1 | Happy (floats up) |
| `tomo-sweat` | 1 | Sad |
| `tomo-anger` | 1 | Misbehaving |
| `tomo-scold` | 1 | Scold effect |
| `tomo-sparkle` | 1–2 | Evolving, cured |
| `tomo-badge-perfect`, `-good`, `-ok`, `-fail` | 1 each | Follow Me results |

### Scenes

| Item | Frames | Used in |
|---|---|---|
| `tomo-bg-day` | 1 | Main scene background (landscape, roughly 3:2; keep the middle clear for the character) |
| `tomo-bg-night-sky` | 1 | Birth and ending sky |
| `tomo-twinkle` | 2 | Small stars twinkling in the night sky |
| `tomo-shooting-star` | 1 | Birth step 2: star with its trail crossing the sky |
| `tomo-star-falling` | 1 | Birth step 3: close-up of the star coming down |
| `tomo-ground` | 1 | Birth step 3–4: the ground it lands on |
| `tomo-star-fallen` | 1–2 | Birth step 4: the star on the ground (the app adds the speeding-up pulse and glow) |
| `tomo-burst` | 1–2 | Birth step 5: the burst of light |
| `tomo-star-fixed` | 1–2 | Ending: the fixed star (the app twinkles it; the departed character is its own `idle-1`, faded) |

### Birth and ending timing

| Step | Length | Skippable |
|---|---|---|
| 1. Night sky | 1.5 s | ✅ |
| 2. Shooting star crosses | 2 s | ✅ |
| 3. Close-up: falls to the ground | 1.5 s | ✅ |
| 4. Pulses, slow to fast | **30 s** (rulebook §3) | ❌ real wait |
| 5. Burst, Baby appears | 1.5 s | ✅ |
| Ending: tomomix fades into the fixed star | 3 s, then stays | ✅ (the transition only) |

### Interface

| Item | Notes |
|---|---|
| 8 care icons: `tomo-icon-food`, `-light`, `-game`, `-medicine`, `-clean`, `-status`, `-discipline`, `-attention` | One drawing each. The app dims and lights them. |
| Status icons: `tomo-meter-hunger` (stomach), `tomo-meter-happy` (heart or smiley), `tomo-meter-discipline` (brain) | §15 |
| Light menu: `tomo-light-on`, `tomo-light-off` | Food choices reuse `tomo-meal` and `tomo-snack`. |

## 6. Checklist

Character names for file names: `baby`, `child-good`, `child-bad`, `teen-excellent`, `teen-good`, `teen-bad`, `1a`…`1d`, `2a`…`2d`, `3a`…`3d`.

**Core poses** (✅ needed to appear in the game)

| Character | idle ×2 | eat ×2 | refuse | happy | sleep | sick | look |
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

**Extra poses** (nice to have)

| Character | blink | sad | call | pout | scolded |
|---|---|---|---|---|---|
| baby | ☐ | ☐ | ☐ | — | — |
| children, teens, adults | ☐ each | ☐ each | ☐ each | ☐ each | ☐ each |

**Totals:** 17 characters × 9 core drawings = **153 core drawings**. With every extra pose, about 236. Plus about 40 shared items in §5.

## 7. Suggested order

1. **Baby, complete** (core + extras), plus the meal, snack, poop and Zzz props. This is the test run of the whole pipeline from Figma into the app.
2. **The birth scene** (§5), since it's the first thing every player sees.
3. **Children and teens** (5 characters).
4. **Adults**, one tier at a time.
5. Interface icons, last: the placeholders work fine in the meantime.
