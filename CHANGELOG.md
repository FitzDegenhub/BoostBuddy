# BoostBuddy Changelog

## 1.1.1 — 2026-08-08

- **Session-forming row.** Join a crew and pay before the first run? The
  Ledger now shows a green "now" row immediately - crew name and gold
  already counted - so paying never looks like a black hole. The row
  becomes a real session at the first counted run.
- **Ledger CSV export.** A CSV button in the Ledger's corner exports your
  sessions - date, crew, runs, XP, averages, length, levels, gold, notes -
  ready for any spreadsheet. (The per-run `/boost export` is still there.)
- **The instance counter is out of the windows.** No more "instances: N/5"
  in any title. Hitting the hourly cap now prints a single red chat line
  with the unlock time, and that is all.

## 1.1.0 — 2026-08-08 — The Money Update

BoostBuddy now answers the third question: how many runs, from whom - and
**for how much**.

- **Automatic trade capture.** Completed trades are logged (cancelled ones
  are not) and tagged to the crew you're running with - paying any member
  of the crew lands on the right session. Rebuys simply stack: 150g now and
  150g later show as 300g on the one session.
- **The Ledger prices your sessions.** New GOLD column with per-day and
  lifetime totals ("...spent" as a customer, "...earned" as a booster).
  Expand a session and every run shows its share of the cost. Click the
  GOLD cell to enter or adjust what you paid; click the NOTE cell to write
  or edit crew notes (all notes are private to you - nothing is ever
  broadcast).
- **Boosters get their books.** Roster customers show red "unpaid" until
  their trade lands (or `/boost paid Name 300` sets it manually), with
  payment status on hover. Right-click a customer row to keep a private
  note on them; your notes greet you in chat whenever a noted player joins
  your group. When a count completes every package, the addon announces
  the session is complete.
- **Rested advisor.** The overlay shows roughly how many boosted runs your
  rested bonus still covers - rested doubles the kill XP you're paying for.
- **`/boost spent 280`** records gold paid outside a trade window (add a
  crew name to attribute it when you're not grouped).
- The hourly instance counter now only appears as a warning at 4/5 and 5/5
  instead of sitting in the title permanently.

## 1.0.12 — 2026-08-08

**The Ledger.** A new History window (button next to Overlay) shows your runs
as boost sessions - grouped by day and crew, expandable down to individual
runs, with class-colored crew names, per-crew run numbering, session length,
level progress, and a NOTE column for your own crew reputation notes
(right-click a session to write one; notes greet you in chat when you join
a group led by someone you've noted). Sessions can be deleted (with
confirmation). Crew identity survives leadership handoffs - the seller
passing lead to a booster mid-package no longer splits your history.

**Session lifecycle fixes** (thanks to a sharp bug report):
- The final run of a package now collects and banks XP properly - it used
  to freeze XP the moment the count hit N/N.
- Leaving or disbanding a group ends the session: finished packages are
  retired immediately, so the next crew starts with clean package buttons.
  Unfinished packages survive - owed runs stay owed.
- On a true login, finished packages older than ~8 hours are cleaned up.
- `/boost reset` now actually resets: confirmation popup, clears all
  packages and synced state, keeps history. Role re-picking is `/boost role`.
- A departed booster's synced state now expires instead of haunting the
  window (which also restores XP tracking and the package buttons).

**Lockout tracking**: the window title shows instances entered this hour
(account-wide, like the real 5-per-hour cap) with a countdown when capped.

**Also**: boosters now record run history too (the Ledger works for both
roles; no customer names are ever stored), plus footer layout and window
stacking fixes.

## 1.0.11 — 2026-08-07

- **Level-up ETA**: the "level up in ~N runs" projection now also shows the
  estimated time (for example "~15 runs (~3h 22m)"), on both the overlay and
  the stats window. The pace comes from the wall-clock time between your
  recent run completions - including reset and regroup downtime - so the ETA
  reflects how boosting actually flows, not just time spent inside.

## 1.0.10 — 2026-08-06

- Count announcements now read "Name - Run 3/10", making it obvious the
  number is the run currently underway, not runs already consumed.
- The last run of a package announces loudly and unmistakably:
  "Name - FINAL Run 10/10 Begins Now!" - the run just starting is still
  owed, and it is the only line in the addon that shouts.

## 1.0.9 — 2026-08-06

- The last-run announcement now reads "(final run starting now!)" instead of
  "(Last Run!!)", making it unmistakable that the run just beginning is still
  a paid one - counts tick when a run starts, and the old wording could be
  misread as "the package is already finished".
- `/boost total` changes now sync to the customer's live package display
  immediately, like every other package edit already did.

## 1.0.8 — 2026-08-06

- BoostBuddy now understands **NovaInstanceTracker and NovaWorldBuffs**: when
  a group leader running either addon resets the instance, the run counts
  instantly for everyone with BoostBuddy - nothing needed on the resetter's
  side beyond their Nova addon. Both their addon-channel relay (current and
  legacy formats) and their "[NIT] ... has been reset" group-chat line are
  recognized, and reset claims are only ever believed from the group leader.
- Friendlier messages: the routine undo link after automatic counts now reads
  "undo available:" instead of the alarming "miscounted?", and counts that
  land on first mob contact explain why ("the reset itself never reached
  your addon").

## 1.0.7 — 2026-08-06

- Fixed run counting when a package is activated **outside** the instance:
  it now shows 0/N until you zone in, ticks to 1/N on entry, and no longer
  phantom-counts on the first pull.
- Joining a group mid-run and activating a package now correctly adopts the
  current instance as run 1 instead of double-counting when the boosters
  engage.

## 1.0.6 — 2026-08-06

- The **Undo Last** button now asks for confirmation, showing exactly what
  each customer's count would drop to before you commit. The `/boost undo`
  command stays instant for those who prefer it.

## 1.0.5 — 2026-08-06

- Overlay past runs are easier to read: run numbers are now a muted grey
  `#12` prefix and XP values are gold, so double-digit run numbers can no
  longer blur into the XP amount.

## 1.0.4 — 2026-08-06

- Stats (average, pace, XP/hr, level projection) now reflect your **last 5
  runs**, matching the runs shown on the overlay. XP rates change as you level
  mid-session, so a long lookback made the average lag reality.

## 1.0.3 — 2026-08-06

- Averages, pace, XP/hr, and the level projection are now **session-scoped**:
  they cover the current sitting (runs completed less than an hour apart, up
  to 25) instead of mixing in yesterday's lower-level runs. No more "average
  lower than every run on screen".

## 1.0.2 — 2026-08-06

- Averages, XP/hr, and the level projection now consider the last 25 runs
  instead of 10, so full 15-20 run sessions are properly represented.
- Run history storage doubled to the last 100 runs.

## 1.0.1 — 2026-08-06

- **Classic Era support** — one addon for TBC Anniversary and Classic Era; the
  level cap and role detection adapt automatically.
- **Fully silent when idle** — with no runs set, the addon does nothing at all:
  no counting, no ready-check alarm, no XP tracking. It wakes when a package
  is active and goes quiet when the last one completes.
- **`/boost pause`** — explicit off-switch mid-arrangement (the overlay shows a
  reminder while paused).
- **`/boost overlay`** — toggle the floating overlay by command or via the new
  button in the window's bottom-right corner (`hide`/`show` set it directly).
- **Rebuilt `/boost help`** — grouped, annotated command list instead of one
  crammed line.
- Fixed: undoing a count no longer swallows the next run's detection; manual
  counts now bank the run's XP and never block the following automatic count.

## 1.0.0 — 2026-08-06

Initial public release. Supports TBC Anniversary and Classic Era (the level cap, and everything driven by it, adapts automatically).

### Run tracking
- Automatic run counting with three independent detection layers: instance
  reset messages, difficulty-toggle resets, and fresh-instance detection via
  creature GUIDs — runs count even if the resetter has no addon.
- Guaranteed **one count per physical instance**, no matter how many redundant
  reset signals arrive.
- Works in any dungeon or raid — nothing hardcoded; the addon learns the
  tracked instance from where the group zones in.
- Customers added mid-run start at 1/N, since the run in progress is theirs.
- Full counts display **(Last Run)** everywhere, since the count ticks when a
  run starts.

### Booster tools
- Role-based window: pick booster or customer on first open (`/boost role`
  to change).
- One-click customer packages (5/10/20 or any custom amount), +5 rebuys,
  editable totals, confirmed removals.
- Ready check and Reset Instance buttons; reset confirmation announces
  "zone out and back in" to the group.
- Per-run group announcements: one line per customer, alphabetized.
- Suspicious-run detection (too fast, or too little XP for a leveling
  character) with a one-click **[undo last count]** chat link.
- Undo button and command — always safe: undo can only give runs back.

### Customer tools
- "Your Boost: X/N (Set by: booster)" — live-synced from the booster's addon
  with zero setup, or self-tracked with one click when no booster runs it.
- XP-per-run overlay styled after the classic boost trackers: current run
  with live timer, past runs, average, XP/hr, and runs-to-level projection.
- Scrollable run ledger with duration and completion time per run.
- CSV export of the full run history.
- Wipe protection: confirmation dialog plus `/boost xprestore` undo.

### Trust & sync
- Corrections are slash-only and **always announced** to the group with the
  actor's name — the tally is a receipt, and nobody edits it in secret.
- One-way sync: a booster's numbers override a customer's self-tracking while
  the booster is in the group; nothing a customer does can alter a booster's
  ledger.
- Reset relays accepted only from the group leader; with multiple trackers,
  the fullest roster is elected sole announcer — no chat spam.
- Catch-up handshake: reloads and late joiners receive the current state
  automatically.

### Quality of life
- Movable overlay and window, both persistent across reloads and zoning.
- Fully silent when idle: with no runs set, the addon does nothing — no
  counting, no alerts, no XP tracking. It only wakes up when a package is
  active, so forgetting it "on" during casual dungeons costs nothing.
- `/boost pause` — full off-switch for casual runs with friends: no counting,
  no alerts, no XP tracking until resumed (the overlay reminds you it's paused).
- `/boost hide` — hide/show the overlay.
- Minimap button, `/boost` + `/bb` slash commands.
- `/boost placeholder` — screenshot mode with fake names on all displays.
- Run clock and XP survive `/reload` and relogging mid-run.
