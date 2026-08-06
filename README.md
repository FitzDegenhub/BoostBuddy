<div align="center">

# BoostBuddy

**Automatic dungeon boost run tracking for WoW Classic.**
Counts runs on every reset, manages customers' paid packages, and shows boostees their XP per run — with zero setup.

[![Version](https://img.shields.io/badge/version-1.0.1-7dc243?style=flat-square)](https://github.com/FitzDegenhub/BoostBuddy/releases)
[![License: GPLv3](https://img.shields.io/badge/license-GPLv3-e8c860?style=flat-square)](LICENSE)
[![TBC Anniversary](https://img.shields.io/badge/WoW-TBC%20Anniversary-5db3e8?style=flat-square)](#installation)
[![Classic Era](https://img.shields.io/badge/WoW-Classic%20Era-5db3e8?style=flat-square)](#installation)

*Selling carry runs? Buying them? Someone always ends up tallying runs on a piece of paper, and someone always ends up arguing about the count.*

BoostBuddy replaces the paper, the arguing, and the *"wait, was that 7 or 8?"* with automatic, tamper-evident tracking that both sides of the trade can see.

</div>

---

## Pick Your Side

<div align="center">

![Role chooser](https://i.imgur.com/BfmqK9G.png)

</div>

The first time you open BoostBuddy it asks one question: **are you a booster or a customer?** Your answer locks in a view built for your job. Change it anytime with `/boost role`.

## For Boosters

<div align="center">

![Booster view](https://i.imgur.com/9IurAud.png)

</div>

- **Automatic run counting.** A run ticks the moment the instance resets. No clicking, no typing, no forgetting.
- **One-click customer management.** Every group member appears in the window with **5 / 10 / 20** package buttons, or set any custom amount. Rebuys are one click, and package sizes can be edited mid-session.
- **Chat receipts for every run.** The group sees a clean announcement each run: one line per customer, with a **(Last Run!!)** tag when someone is on their final one.
- **Ready Check & Reset Instance buttons.** Run your whole reset cycle from one window, with a loud alarm that wakes up AFK customers.
- **Mistake-proof.** Accidental reset after a botched pull? The addon flags suspicious runs (too fast, or too little XP) and offers a one-click **[undo last count]** link right in chat. Undo is always safe: it can only give runs back.
- **Tamper-evident by design.** There are no quick count-adjust buttons anywhere. Every manual correction is a deliberate command that announces itself to the whole group with the name of who did it. The tally is a receipt, and nobody edits a receipt in secret.

## For Customers *(the ones being boosted)*

<div align="center">

![Customer view](https://i.imgur.com/NkffGna.png)

</div>

- **Your package, live.** *"Your Boost: 6/20"* on your screen, synced automatically from your booster's addon. When they add you, count you, or extend your package, you see it instantly, labeled with who set it.
- **XP per run, like the classic boost trackers.** A clean overlay with your current run (live XP and timer), your past runs, average per run, XP per hour, and a *"level up in ~N runs"* projection.
- **Works even if nobody else has the addon.** Run detection happens on *your* client too. No booster with BoostBuddy? Track your own package with a click and everything still counts automatically.
- **Your data is yours.** A full, scrollable run ledger in the window, CSV export for the spreadsheet enjoyers, and wipe protection with undo so a misclick can't destroy your history.

---

## How the Counting Works *(the nerdy bit)*

BoostBuddy detects completed runs three independent ways, and uses whichever fires first:

1. **Instance reset messages**, seen by the resetter and relayed silently to every BoostBuddy in the group.
2. **Difficulty-toggle resets**, the *"(All saved instances have been reset)"* message the whole group sees.
3. **Fresh-instance proof via creature GUIDs.** Every mob carries an ID that changes when an instance is reset. If the mobs are new, the run counted — even if every reset message was missed and the resetter has no addon at all.

A guard system guarantees **exactly one count per physical instance**, no matter how many redundant signals arrive. Multiple people running the addon? They elect one announcer. No chat spam, ever.

Works in **any dungeon or raid**. Nothing is hardcoded: the addon learns what you're running by watching where the group zones in.

> **And when no runs are set, BoostBuddy is completely silent.** No counting, no alerts, no XP tracking. It only wakes up while a package is active, so leaving it enabled costs you nothing in your normal dungeons.

---

## Installation

**Addon managers:** available on CurseForge and Wago — search *BoostBuddy*.

**Manual:** grab the zip from [Releases](https://github.com/FitzDegenhub/BoostBuddy/releases), extract the `BoostBuddy` folder into:

```
World of Warcraft/_anniversary_/Interface/AddOns/     (TBC Anniversary)
World of Warcraft/_classic_era_/Interface/AddOns/     (Classic Era)
```

One addon serves both flavors — the level cap and role detection adapt automatically.

## Commands

Type `/boost help` in game for the full annotated list. Highlights:

| Command | What it does |
| --- | --- |
| `/boost` or `/bb` | Open the window (also: minimap button, or right-click the overlay) |
| `/boost overlay` | Toggle the floating overlay (there is a button for it in the window too) |
| `/boost pause` | Full off-switch: no counting, alerts, or XP tracking until resumed |
| `/boost role` | Re-pick booster or customer view |
| `/boost add Name 10` | Track a customer (or just click names in the window) |
| `/boost count` / `undo` | Manual run count / take the last count back (announced) |
| `/boost ready` | Start a ready check |
| `/boost export` | Your run history as copyable CSV |
| `/boost placeholder` | Screenshot mode: fake names on all displays |

---

## FAQ

<details>
<summary><strong>Does the booster or the customer control the count?</strong></summary>

The booster's addon is authoritative: while a booster is tracking you, their numbers are what you see, and nothing you do on your side can change them. Customer self-tracking is a fallback for when no booster runs the addon.
</details>

<details>
<summary><strong>Can a booster quietly bump my count?</strong></summary>

No. Automatic counts announce their source (*"The Slave Pens reset"*). Every manual change announces itself with the actor's name, and in-window controls for silent adjustments simply do not exist.
</details>

<details>
<summary><strong>Will it interfere with my normal dungeon runs with friends?</strong></summary>

No. With no active packages the addon does literally nothing: no sounds, no messages, no tracking. There is also `/boost pause` as a hard off-switch mid-arrangement, and `/boost overlay` to hide the display.
</details>

<details>
<summary><strong>Does everyone need the addon?</strong></summary>

No. One booster with BoostBuddy gives the whole group announcements in party chat. Customers who install it additionally get the live package display and XP tracking, with zero configuration.
</details>

<details>
<summary><strong>What about Blizzard's boosting rules?</strong></summary>

BoostBuddy is a run tracker for boost runs traded **in-game for gold**, which Blizzard permits for individual players and guilds. It is not affiliated with any boosting service or community, contains no matchmaking or payment features, and real-money trading violates the Blizzard ToS. Don't do it.
</details>

---

<div align="center">

*Built for WoW Classic: TBC Anniversary & Classic Era • No dependencies • No configuration • No nonsense*

**Free and open source ([GPLv3](LICENSE))** • Issues and pull requests welcome

</div>
