# BoostBuddy Changelog

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
