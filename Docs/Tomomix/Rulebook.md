# Tomomix Rulebook — draft 5

The rules for **Tomomix**, TamaEmu's built-in virtual pet. One pet is a *tomomix*; several are *tomomixis*. It ships with the app and needs no ROM. All characters, art, names and wording are original.

**Baseline:** the classic first-generation virtual pet care rules, from our research notes. Rule IDs like `GR01` refer to those notes. Tomomix keeps those rules where they make sense and changes the life structure, the presentation and the controls.

## How to read this

Every rule carries one tag:

| Tag | Meaning |
|---|---|
| **Classic** | Same as the classic rules. The research checked it. |
| **Choice** | The classic rule is unknown, or doesn't fit our cast, so this is our decision. |
| **Change** | Deliberately different from the classic rules. |
| **Phone** | Something a toy never had to deal with, such as the app being closed. |

**Time unit:** unless stated otherwise, "minutes" means **awake minutes**: minutes when the tomomix is alive, born and not asleep. A tomomix that sleeps 11 hours a night takes much longer than 23 wall-clock hours to use up "23 hours" of growth.

---

## 1. The cast — 19 characters

| Stage | Characters | Your art |
|---|---|---|
| Fallen star | 1 (birth, §3) | |
| Baby | 1 | |
| Child | **Good Child · Bad Child** | |
| Teen | **Excellent Teen · Good Teen · Bad Teen** | |
| Adult, Excellent tier | 1A · 1B · 1C · 1D | |
| Adult, Good tier | 2A · 2B · 2C · 2D | |
| Adult, Bad tier | 3A · 3B · 3C · 3D | |
| Departed (ending, §12) | each character's own art, faded | — |

The three teens match the three adult tiers: the Excellent Teen points toward the Excellent tier, and so on. Within each tier, the four types (A–D) reflect discipline.

**Change:** the classic chart has 1 child, 2 teens with hidden subtypes, 6 adults and 1 secret. Tomomix has 2 children, 3 teens with no hidden subtypes, 12 adults and **no secret character**.

## 2. Controls

**Classic buttons**

| Rule | Tag |
|---|---|
| **A** moves through the 7 care icons. **B** confirms. **C** cancels or goes back to the tomomix. | Classic `UI03` |
| Icons, top row: Food · Light · Game · Medicine. Bottom row: Clean · Status · Discipline · **Attention** (lights up by itself and can't be selected). | Classic `UI01` |
| Moving the cursor or opening menus never clears a call. Only the right care action does. | Classic `UI02` |
| **A + C** on the main screen turns sound on or off. Calls still show on screen when muted. | Classic `UI04` |
| While asleep, only Light and Status work. Nothing works during the birth (§3). | Classic `UI06` |
| **Outdoors.** On the main screen with no icon highlighted, **B** — or **a tap anywhere except on the tomomix** — takes it out to the meadow, and the same brings it back to the room. Everything works the same outside. Its star lands outdoors, but it always hatches into the room. It always sleeps inside: when it falls asleep or the light goes off, it goes in by itself, and B can't take it out until it's up and the light is on. | Change |

**Tap shortcuts (hidden)**: Change

The buttons are the classic way to play. Tapping is a quicker, modern way to do the same things. Neither is advertised as the "real" way: players can use whichever they prefer, and mix them.

| Tap | Does the same as |
|---|---|
| Any of the 7 care icons | Pressing A until that icon is selected, then B |
| A food (meal or snack) in the food menu | Selecting it and pressing B |

**Tap the tomomix.** When it's doing fine (awake, not sick, not calling or misbehaving, and no thought bubble), tapping it makes it hop in surprise with its happy face. Otherwise a tap does what the next paragraph says. Change

**Menus close by themselves.** Left alone for **3 seconds**, an open menu (food, light, status) closes, and a highlighted icon goes back to none. Games and animations don't. Change

**Tap the screen to skip.** Tapping the screen itself (not an icon or a choice) skips the animation that's playing, or closes whatever can be closed: status, a menu, a game result. It never skips a real wait, like the fallen star's 30 seconds, or the game's sequence. Change

Tapping follows the same rules as the buttons. Anything that's blocked (while asleep, during the birth, during an animation) is blocked for taps too.

**Settings and ⋯ menu**: Phone. Extra options live behind the cog and ⋯ buttons. See §17.

## 3. Birth — the shooting star

| Step | What you see | Tag |
|---|---|---|
| 1 | A starry night sky, with **shooting stars passing every few seconds**. Nothing happens until the player catches one: **a tap anywhere on the screen, or any button (A, B or C), while a star is flying** catches it (just after it leaves still counts). | Change |
| 2 | The caught star glides to the top and waits while **"Your name?"** fades in (first time only; Skip is fine, and the name can be set later in Settings). | Change |
| 3 | Close-up: the star falls onto the meadow (the outdoors, in stronger night colors). | Change |
| 4 | The fallen star **pulses for 30 seconds**. It starts slow and pulses faster and faster as the birth gets closer, while the starry night slowly fades into the real sky of the time of day. No care is possible. | Change (classic egg: 5 min) |
| 5 | The star **hops up and bursts** (`tomo-evolution`) as the screen fades to white; from the white the Baby appears **in the room**. It's born with empty meters, so it **calls right away**. | Change |
| 6 | **"Name your baby"** appears above it (Skip is fine). The name stays through every stage, and shows on the status screen, the ending and notifications. Up to 10 letters. | Change |

The player's name is shared by every tomomix they raise. Notifications use both names when given, for example "Mochi is hungry, Sam!" (§16).

| Rule | Tag |
|---|---|
| There's no clock setup. Tomomix uses the phone's clock (with an optional offset, §17). | Phone |
| The Baby is born with **empty hunger and happiness meters**, so feed it straight away. | Classic `LS04` |
| The Baby weighs **5** and never gains or loses weight. | Classic `FD04` |
| The Baby naps after **40 awake minutes** and sleeps **5 minutes**. Waking from the nap is its first birthday (§9). | Classic `LS06` |
| The Baby becomes a Child after **60 awake minutes** (about 65 minutes total, nap included). | Classic `GR03` |
| Once a life has ended, **A + C** brings back the starry night, ready to catch a new shooting star. The same option is also in the menus (§17). | Classic `LS05` + Phone |

## 4. Hunger and happiness

| Rule | Tag |
|---|---|
| Hunger and happiness each have **5 levels** (empty + 4 steps). Each drops one step on its own timer (§14). | Classic `TM01` |
| Refilling a meter does **not** restart its timer. The countdown keeps going. | Classic `TM01` `EV01` |
| **Wobbly timers:** each time a meter's timer restarts, it gets a random **±20%**. "Every 50 minutes" becomes anywhere from 40 to 60, and the average stays the same. | Change |
| Meters don't drop during sleep. | Classic `TM03` |
| On evolving, timers keep whatever time they had left. The new character's interval applies from the next time a timer restarts. | Classic `TM04` |
| **Thought bubble:** when a meter is down to its **last step**, a thought bubble shows what it'll soon want: the meal for hunger, the snack for happiness, or both. It's a heads-up before the call. Hidden while asleep, sick or during an animation. | Change |

## 5. Food and weight

| Rule | Tag |
|---|---|
| **Meal:** +1 hunger step, +1 weight. | Classic `FD01` |
| **Snack:** +1 happiness step, +2 weight. | Classic `FD02` |
| The tomomix refuses food when it's full, sick, asleep or misbehaving (§8). Refused food does nothing. | Classic `FD03` |
| Weight stays within the character's range (§14). The top limit is 99. | Classic `FD04` |
| Food is unlimited. There's no money, shop or stock. | Classic `FD05` |
| After eating (or refusing), the food menu comes back with the **same choice selected**, so feeding several snacks is quick. Leaving the menu resets it to Meal. | Change |
| Weight doesn't affect growth. | Classic `FD06` |
| Each snack given at full happiness takes **15 minutes** off the healthy timer (§10). | Choice `HL08` `U07` |

## 6. The mini-game — Follow Me

A memory game: the tomomix shows a sequence of directions, and you repeat it. Change (the classic game is a left/right guess)

It's played **right where the tomomix is** (the room or outdoors), with nothing resizing: it stands in the middle and looks each way, two arrows (`tomo-arrow`) appear at the left and right sides (lit when shown or pressed; each half of the screen is the tap target). No text and no thought bubble or spiral during the game. It opens with a bouncy "let's play!" tune while it hops for joy (1.4 s), and ends with the happy chime (it won happiness) or the sad one.

| Rule | Tag |
|---|---|
| Up to **5 rounds**. Round 1 is 1 direction long, round 2 is 2, and so on up to 5. | Change |
| Each round **repeats the previous sequence and adds one new random direction** at the end (left → left, right → left, right, right …). | Change |
| The tomomix shows each direction by turning or pointing left or right. Left and right each have their own beep. | Change |
| You repeat the sequence with **A = left, B = right**, or by tapping the left or right side of the screen. **C** quits. | Change |
| **A wrong direction ends the game.** Your score is the number of rounds you completed. | Change |
| If you don't press anything for **5 seconds**, that counts as a wrong direction. | Choice |

**Results**

| Score | Result | Happiness |
|---|---|---|
| 5 | Perfect | +3 steps |
| 3–4 | Good | +2 steps |
| 1–2 | OK | +1 step |
| 0 | Fail | none |

| Rule | Tag |
|---|---|
| Happiness never goes above 4 steps. | Classic `GM01` |
| Finishing a game takes off **2 weight per round completed**: 10 for a perfect game, 8, 6, 4, 2, and none for 0 rounds. Never below the character's minimum. A game that ends on a wrong direction counts as finished. | Change (classic `GM02`: 1 per game) |
| Quitting with C before the end gives no happiness and costs no weight. | Choice |
| The result shows for **2.5 seconds**, then the game closes by itself. A tap or a button closes it sooner. | Choice |
| The game can't be played while asleep, sick or refusing. | Classic `GM03` |

## 7. Calls and care mistakes

A **call** is the tomomix asking for something. The attention icon lights up and it beeps.

| Rule | Tag |
|---|---|
| It calls when hunger empties, when happiness empties, and when it falls asleep with the light on. | Classic `CR01` |
| A hunger or happiness call that goes unanswered for **14 minutes** counts as **1 care mistake**. | Classic `CR02` `CR03` |
| Leaving the light on for **about 60 minutes** after bedtime counts as **1 care mistake**, only once per night. | Classic `CR04` |
| One step of food or happiness is enough to answer a call. If both meters are empty, both need at least one step. | Classic `CR05` |
| Hunger and happiness share **one** 14-minute deadline. If both are empty, it's still only 1 mistake when time runs out. | Choice `CR06` `U05` |
| Care mistakes (**C**) add up from Baby onward and are never erased. | Classic `CR07` |
| The attention icon **stays lit while hunger or happiness is empty**, until the need is met. When the 14 minutes run out, the care mistake still counts, but the icon doesn't go out. | Change (classic: it goes out on its own) |

## 8. Discipline

Sometimes the tomomix calls even though it doesn't need anything, or refuses food or games while hungry or unhappy. That's **misbehavior**.

| Rule | Tag |
|---|---|
| Choosing **Discipline** during misbehavior raises the discipline meter by **10%**. It takes **10 scolds** to reach 100%. | Change (classic: 4 steps of 25%) |
| Misbehavior that goes undisciplined for **14 minutes** counts as **1 discipline mistake (D)**. | Classic `DS03` |
| **D** is counted separately from the meter. Filling the meter later doesn't erase it. | Classic `ST01` |
| Misbehavior happens after a number of meter drops, not on a clock. Each time, the number is picked at random: **5–7** for Children and Teens, **6–8** for adults. (Classic: exactly 6 and 7.) | Classic `DS04` + Change |
| At 100% discipline the tomomix stops misbehaving. | Classic `DS05` |
| Disciplining a tomomix that genuinely needs food or play doesn't count. | Classic `DS01` |
| **Starting discipline when evolving** (replaces the classic hidden-subtype rule): | |
| · Children start at 0%. | Classic |
| · Teens start at 50% if D is 0–2, or 0% if D is 3 or more. | Choice (based on Classic `DS07`) |
| · Adults start by type, whatever their tier: **A 100% · B 80% · C 20% · D 0%**. | Choice |

**What changes because of the new chart:** the classic rules set a teen's starting discipline from its hidden subtype, and each adult had its own fixed starting level. Tomomix has no subtypes and four discipline-based adult types, so both rules above are new. The adult numbers are the average of the classic good-care and poor-care adults for each discipline band, rounded to the 10% steps. Scolds are smaller (+10%) and the timing of misbehavior is unchanged, so a full meter takes longer to earn than in the classic.

## 9. Sleep, lights and age

| Rule | Tag |
|---|---|
| Each character has its own bedtime and wake-up time (§14). | Classic `SL01` |
| Turning the light off doesn't make the tomomix sleep. It's the right response once it's asleep. | Classic `SL02` |
| The light turns back on automatically when it wakes. | Classic `SL02` |
| Age goes up **by 3 each time it wakes up**: 1 day = 3 years. Waking from the baby nap makes it 3. | Change (classic: +1 per wake) |
| Age has no upper limit. | Change (classic: max 99) |

## 10. Poop and sickness

| Rule | Tag |
|---|---|
| First poop comes 15 minutes after birth. After that, every **25 minutes** for the Baby and every **180 minutes** for everyone else. | Classic `HL01` |
| Up to **8** poops can pile up, shown as small and big piles (table below). After 8, no more are added. | Change `U06` |
| Cleaning removes all poop at once. | Classic `HL02` |
| Cleaning works even when there's no poop: the sweep still plays, just for fun. | Change |
| Each character has a "healthy timer" that counts down while it's awake and well (§14). When it runs out, the tomomix gets sick: a **scribble ball** churns beside its head, and it **stays still in the middle** of the screen with its sick face (no walking, hopping or blinking), **shivering** now and then (a sudden burst of quick left-right jolts, about every 2 seconds), until it's cured. | Classic `HL06` + Change |
| Each poop on screen makes the healthy timer run **25% faster**: 1 poop = ×1.25, 4 poops = ×2, 8 poops = ×3. | Choice `U06` |
| Medicine cures sickness. Some characters need **2 or 3 doses** (§14). | Classic `HL04` `HL05` |
| Getting sick **3 times as the same character** means critical condition (§12). Evolving resets that count. | Classic `HL07` |

**How the poop looks**

| Poops | Shown as |
|---|---|
| 1 | 1 small |
| 2 | 2 small |
| 3 | 3 small |
| 4 | 4 small |
| 5 | 3 small + 1 big |
| 6 | 2 small + 2 big |
| 7 | 1 small + 3 big |
| 8 | 4 big |

## 11. Growing up

Growth depends only on two hidden counts: **C** (care mistakes, §7) and **D** (discipline mistakes, §8). Both start at 0 at birth, only ever go up, and stop at 15. Growth is never random (Classic `GR02`).

**Baby → Child** (after 60 min)

| When | Becomes |
|---|---|
| No care mistakes as a Baby (C = 0) | Good Child |
| Any care mistake as a Baby (C ≥ 1) | Bad Child |

**Child → Teen** (after 1,380 min ≈ 23 awake h, either Child)

| When | Becomes |
|---|---|
| C 0–2 | Excellent Teen |
| C 3–5 | Good Teen |
| C 6+ | Bad Teen |

A Bad Child can still become the Excellent Teen if it gets no more than 2 mistakes in total. The child stage is a first impression, not a final verdict.

**Teen → Adult** (after the teen's growth time, §14)

The adult's **tier** comes from C, using the same bands as the teens. Because C never goes down, a tomomix can only stay in its teen's tier or drop to a lower one.

| C | Tier |
|---|---|
| 0–2 | Excellent (1) |
| 3–5 | Good (2) |
| 6+ | Bad (3) |

The adult's **type** comes from D:

| D | Type |
|---|---|
| 0 | A |
| 1 | B |
| 2–3 | C |
| 4+ | D |

**Why these bands:** the classic splits care mistakes at 3, and splits adult discipline at 1, 2 and 4. Tomomix keeps every one of those cut-off points and adds one new split at 6 for the middle tier.

## 12. Old age and the ending

| Rule | Tag |
|---|---|
| Each adult has a lifetime timer (§14). Once it runs out, the tomomix is **old**. | Classic `CH01` |
| An old tomomix gets hungry and unhappy faster after each wake-up: each interval becomes ¾ of the previous one (81 → 61 → 46 …), never below **10 minutes**. | Classic `EN03` + Choice `U10` |
| An old tomomix that makes **5 more care mistakes** departs. | Classic `EN02` |
| An empty meter for **720 awake minutes in a row** (≈ 12 h) ends the life at any age. | Classic `EN04` |
| Sickness left untreated for about **350 awake minutes** (≈ 6 h) ends the life. | Classic `EN04` |
| A 3rd sickness as the same character means critical condition: continuous alarm, no care possible. After **10 minutes** the life ends. | Classic `EN01` + Choice `U09` |
| All of the above can be switched off with the "no deaths" setting (§17). | Phone |

**The ending — a fixed star.** Change

The tomomix becomes a **fixed star** (the Tomomix star, glowing and floating) at the center of the starry night sky, with a **faint ghost of the departed tomomix** centered behind it. Its **name** shows big near the top and its final age ("6 years old") near the bottom, with a slow, low farewell chime. **Tapping twice** sends a new shooting star (§3): the first tap shows "tap again to shoot a new star" above the age for 2 seconds; a second tap while it shows starts the new star. **A + C**, or the menu option, also sends one.

## 13. Our choices for the unknowns

| Unknown | Decision | Research ID |
|---|---|---|
| Game win odds | Doesn't apply: new game, Follow Me (§6) | `U04` |
| Two empty meters at once | One shared deadline, one mistake | `U05` |
| Poop limit and effect on health | 8 poops, small and big; each one makes sickness 25% sooner (§10) | `U06` |
| Snacks and sickness | Each snack at full happiness takes 15 min off the healthy timer | `U07` |
| Timers when evolving | Keep the time left | `U08` |
| Critical condition length | 10 minutes | `U09` `U11` |
| Old-age interval floor | 10 minutes | `U10` |

## 14. Character numbers

Minutes are awake minutes. *Classic* rows copy a classic character. *Blend* rows sit halfway between the Excellent and Bad versions. Starting discipline follows §8.

| Character | Source | Awake | Hunger / happiness drop every | Weight | Doses | Healthy timer | Grows / ages after |
|---|---|---|---|---|---|---|---|
| Baby | Classic | nap only | 3 / 4 | 5–5 | 2 | 45 | 60 |
| Good Child, Bad Child | Classic | 9:00–20:00 | 50 / 60 | 10–99 | 2 | 990 | 1,380 |
| Excellent Teen | Classic good-care teen | 9:00–21:00 | 75 / 85 | 20–99 | 2 | 1,656 | 2,220 |
| Good Teen | Blend | 9:00–21:00 | 75 / 85 | 20–99 | 2 | 1,158 | 1,800 |
| Bad Teen | Classic poor-care teen | 9:00–21:00 | 75 / 85 | 20–99 | 2 | 660 | 1,380 |
| **1A** | Classic best adult | 9:00–22:00 | 81 / 91 | 30–99 | 1 | 3,900 | 4,095 |
| **1B** | Classic 2nd adult | 9:00–22:00 | 81 / 91 | 30–99 | 1 | 2,808 | 3,120 |
| **1C** | Classic moody adult | 11:00–23:00 | 55 / 65 | 30–99 | 1 | 2,592 | 2,880 |
| **1D** | Classic moody adult | 11:00–23:00 | 55 / 65 | 30–99 | 1 | 2,592 | 2,880 |
| **2A** | Blend 1A + 3A | 9:00–22:00 | 70 / 80 | 25–99 | 2 | 2,535 | 2,828 |
| **2B** | Blend 1B + 3B | 9:00–22:00 | 70 / 80 | 25–99 | 2 | 1,989 | 2,340 |
| **2C** | Blend 1C + 3C | 10:00–22:00 | 57 / 67 | 20–99 | 2 | 1,476 | 1,830 |
| **2D** | Blend 1D + 3D | 10:00–22:00 | 50 / 57 | 25–99 | 2 | 1,626 | 2,160 |
| **3A** | Classic spoiled adult | 9:00–22:00 | 60 / 70 | 20–99 | 2 | 1,170 | 1,560 |
| **3B** | Classic spoiled adult | 9:00–22:00 | 60 / 70 | 20–99 | 2 | 1,170 | 1,560 |
| **3C** | Classic scruffy adult | 9:00–22:00 | 60 / 70 | 10–99 | 3 | 360 | 780 |
| **3D** | Classic wild adult | 10:00–22:00 | 45 / 50 | 20–99 | 2 | 660 | 1,440 |

The classic chart only has three outcomes per care level, so two pairs share numbers (1C/1D, 3A/3B). We can tell them apart once your characters have personalities.

Eating animation: Baby, both Children, Bad Teen and 3C take 4 bites. Everyone else takes 2. (Classic `CH03`)

## 15. Status screen

Change: everything is on **one screen** instead of several pages.

| Shows | How |
|---|---|
| Name | At the top, when it has one (§3) |
| Hunger | Meter with a **stomach** icon, 5 levels (empty + 4) |
| Happiness | Meter with a **heart or smiley** icon, 5 levels |
| Discipline | Meter with a **brain** icon, 10 steps (0–100% in steps of 10) |
| Age | Number (§9) |
| Weight | Number |

Hunger and happiness have 4 steps; discipline has 10, so it fills more slowly.

## 16. Phone rules

| Rule | Tag |
|---|---|
| **Time keeps passing while the app is closed**, like a toy left in a drawer. When the app opens, it catches up straight away. | Phone |
| The app knows when the next call will happen, so it can schedule notifications even while it's closed. | Phone |
| **Growing up is announced.** The app also knows when it will next grow up (growth runs on awake time only), so it sends a notification at that moment, without saying who it became. | Phone |
| **A missed evolution is replayed.** If it grew up while the app was closed and the player opens it within **2 hours**, they see the old character, then the evolution animation. Later than that, or if it has fallen asleep since, it has simply changed. | Phone |
| **Pause** freezes the tomomix: while paused it doesn't age, grow, get hungry or unhappy, poop or get sick, and a pulsing star doesn't get closer to hatching. All its timers resume exactly where they stopped. **The clock doesn't stop**: on resume the sky, bedtime and everything else follow the phone's real time again; the paused stretch is simply skipped. | Phone `LS03` |
| Sleep and wake times use the phone's local time (plus any offset, §17). When time zones change, the tomomix follows the new local time. | Phone |
| Changing the phone's clock by hand doesn't add or remove awake minutes. | Phone `SL04` |

**Surprise without unfairness** (decided 2026-11-18)

| Rule | Tag |
|---|---|
| Random rolls (wobbly timers §4, misbehavior §8) come from a seed saved with each tomomix. Catching up after the app was closed gives exactly the same result as if the app had stayed open, and the app can still schedule notifications ahead. Only the player can't predict them. | Phone |
| **Notifications vary:** each kind of call (hungry, unhappy, bedtime, sick, poop, misbehaving) has several messages, and they can differ by character. The same message never appears twice in a row. | Change |
| **Never random:** the 14-minute and 60-minute deadlines (§7) and the growth chart (§11). A care mistake should always feel fair, and good care should always pay off. | Choice |

## 17. Settings and ⋯ menu

**Free, fully.** Tomomix needs no purchase for anything, and it doesn't count toward the free Tama: a free player can have one Tomomix plus one emulated Tama (never two of either). Its full-screen sky (the ambient background) is always on, for everyone.

**⋯ menu:** Pause / Resume, Send a New Shooting Star, Tomomix Settings, Add a Tama, Rearrange, Delete.

**Tomomix Settings:**

- **Names:** the tomomix's and the player's, editable any time.
- **Sound & Haptics:** Sound on/off (same as A + C), and the app-wide Volume, Haptics and Respect Silent Mode (shared with the other Tamas).
- **Screen:** Appearance (light / dark / automatic, app-wide); Ambient Background, always on ("included free with Tomomix"); Retro Screen (big pixels at 128 across, the same scan lines and glass sheen as the other Tamas; icons and menus stay sharp).
- **Care:**
  - **Notifications** on/off (its calls, when the app isn't open).
  - **Difficulty:** Easy / Classic / Hard. Easy stretches hunger and happiness timers, call and discipline deadlines and the healthy timer by 1.5×; Hard shrinks them to 0.75×.
  - **No Deaths:** its life never ends. Old age just stays old; an empty meter too long makes it sick instead; untreated sickness and a 3rd sickness don't lead to an ending.

Decided against: a clock offset (pause now freezes its life without shifting the clock, which covers most of that need).

## 18. Ideas for later (not active)

- Give 1C/1D and 3A/3B their own numbers once each character has a personality.
- The night sky could keep a star for every past tomomix, so it fills up over time.
- **Personality at birth:** each tomomix rolls a small lifelong trait, such as "big eater" (hungry a bit faster, happy a bit slower) or "night owl" (sleeps an hour later).
- **Small random moments:** animation-only moments like a sneeze, a dance or a stare at the sky. They don't change any numbers.
- Wobbly timers for poop as well.

## 19. Still to design

Everything above is confirmed as the baseline. Nothing is open right now.

