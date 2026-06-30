# LapWork — Project Context

Native macOS **menu bar** app (Swift 6.2 / SwiftUI, Xcode 26.3, macOS 26). A
focus timer that **earns break time**, used as a self-experiment tool to find
optimal work/break settings. It **logs time only — it does not judge
productivity.** The user journals what they did per lap in a paper notebook,
keyed by lap number, and analyzes externally (often by handing the CSV + a
notebook photo to an AI).

## App shape

- `MenuBarExtra` app, `.menuBarExtraStyle(.window)`.
- `LSUIElement = YES` (agent app — no Dock icon, no main window).
- Preferences via the SwiftUI `Settings` scene (⌘,).
- Project uses `PBXFileSystemSynchronizedRootGroup`: **any `.swift` file added
  under `LapWork/` is automatically compiled — no `project.pbxproj` edits
  needed.**

## Core mechanics

### Laps (focus blocks)
- Default **12 min**, customizable. Numbered, **reset to L1 each day**.
- **Manual advance only.** When a lap ends it rings (bell + banner) and WAITS.
  The user clicks **Start Lap** to begin the next. No auto-advance.
- **Interrupting/canceling mid-lap = forfeited.** Earns nothing, logs nothing.
  There is no pause. A lap only counts (and is logged) if completed.

### Gas (the earned break bank)
- Completing a lap adds `lapLength × accrualPercent` to Gas. Default accrual
  **20%** → a 12-min lap earns **2.4 min**. Partial laps earn **zero**.
- **Take Break** drains Gas **live in real time** (click to start, click to
  stop; remainder stays banked).
- Gas may go negative as overdraft down to a **floor of −5 min** (configurable).
  At/below the floor, Take Break is disabled and an active break auto-stops.
  Gas shows **red** when negative.
- Gas **flushes to 0 at the daily reset** (use it or lose it).

### Diary ritual
- **Open Diary** (morning) → session mode. Menu bar shows lap info.
- **Diary Complete** (night) → finalizes the day: flushes Gas, makes export
  ready, resets lap numbering. Forfeits any running lap.
- Menu bar label: `⊙` when diary **closed**; `L7 · 8:42` during a running lap
  (number + mm:ss countdown); `L7 done` in the gap after a completed lap until
  the next is started; `L1 ▸` when open and ready with no lap yet.

## Persistence model — TWO separate stores (important)

1. **Ephemeral state** → UserDefaults (`lapwork.state.v1`), one JSON blob
   (`PersistedState`): Gas, settings, lap progress, diary state. May be
   flushed by the daily reset. Survives quit/restart. Running laps and breaks
   resume from absolute timestamps.
2. **Permanent experiment log** → `Application Support/LapWork/log.json`,
   append-only (`{laps, breaks}`). **Never touched by the Gas flush.** This is
   the experiment data.

Each `LapRecord`: date, lapNumber, startTime, endTime, lapLengthMin,
accrualPercent, gasEarnedMin. Each `BreakEvent`: date, start, end, drainedMin.

## CSV export

Per-day CSV → `Application Support/LapWork/exports/LapWork-<yyyy-MM-dd>.csv`,
revealed in Finder. Lap section keyed by lap number
(`date,lap_number,start_time,end_time,lap_length_min,accrual_percent,gas_earned_min`),
then a break section (`break_index,date,start_time,end_time,gas_drained_min`).
Reachable from the dropdown ("Export Today's CSV…").

## Files

| File | Role |
|------|------|
| `LapWorkApp.swift` | App entry; owns `TimerEngine` (`@StateObject`); `MenuBarExtra` + `Settings` scenes; dynamic label. |
| `TimerEngine.swift` | `@MainActor ObservableObject` — the brain: lap countdown, Gas math, diary/day state, bell+banner. Time is wall-clock based (drift-free, resumes across restart). 250 ms ticker via a `Task` loop. |
| `Models.swift` | `FocusSettings`, `LapRecord`, `BreakEvent`, `PersistedState` (all `Codable`/`Sendable`). |
| `DiaryStore.swift` | `@MainActor` persistence: UserDefaults state + append-only JSON log + CSV export + date helpers. |
| `NotificationManager.swift` | `UNUserNotificationCenter` wrapper + delegate (banners show even though we're an agent app). |
| `ContentView.swift` | The dropdown panel. Holds no timer state. |
| `SettingsView.swift` | ⌘, preferences; edits a draft, pushes to engine `onChange`. |

## Conventions / gotchas

- **Swift 6 strict concurrency**: `TimerEngine` and `DiaryStore` are
  `@MainActor`. The notification delegate methods are `nonisolated`. Keep new
  state mutation on the main actor.
- Time math uses absolute `Date`s, never decremented counters — so countdowns
  stay correct across sleep/lag/quit. Don't reintroduce tick-based counters.
- Settings changes apply on the **next** lap (lap length/accrual are captured
  into the `LapRecord` at completion from the live settings).
- Build/verify: `xcodebuild -project LapWork.xcodeproj -scheme LapWork
  -destination 'platform=macOS' build`.
