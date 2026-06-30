# Changelog

All notable changes to LapWork are documented here.

## [Unreleased]

### Changed
- Menu bar label now shows live **break time** while a break is running
  (`☕ 2:18`, counting the Gas down), instead of holding the lap label.
- Gas / break time is now displayed as a clock (`m:ss`, e.g. `2:24`, `-1:30`)
  everywhere instead of a decimal minutes value — matching the lap countdown.
  Added `TimerEngine.clock(minutes:)` (signed, minutes→`m:ss`).

### Fixed
- Settings window opening behind everything from the menu bar. Use the native
  `SettingsLink` to open the Settings scene, with an
  `NSApp.activate(ignoringOtherApps:)` gesture so the window comes to the front
  (agent apps — `LSUIElement`, `.accessory` policy — otherwise open it behind
  all other windows).

## [0.1.0] — 2026-06-30

First functional build. Turned the scaffold (MenuBarExtra + default
ContentView) into the full focus-timer / earned-break tool.

### Added
- **`Models.swift`** — value types:
  - `FocusSettings` (lap length, accrual %, overdraft floor, sound &
    notification toggles) with derived `gasPerLapMin` / `overdraftFloor`.
  - `LapRecord` — permanent per-lap experiment record (date, lap number,
    start/end, lap length, accrual %, gas earned).
  - `BreakEvent` — permanent per-break record (date, start/end, gas drained).
  - `PersistedState` — single ephemeral state blob (Gas, settings, lap
    progress, diary flags, live-break state).
- **`DiaryStore.swift`** — `@MainActor` persistence layer with two separated
  concerns:
  - Ephemeral state in UserDefaults (`lapwork.state.v1`).
  - **Permanent append-only log** in `Application Support/LapWork/log.json`
    (never cleared by the daily Gas flush).
  - **CSV export** (`csv(for:)` / `exportCSVFile(for:)`): per-day, lap section
    keyed by lap number plus a break section → written to
    `Application Support/LapWork/exports/`.
  - Date helpers (`dayKey`, time formatting).
- **`TimerEngine.swift`** — `@MainActor ObservableObject`, the brain:
  - Lap countdown using **absolute wall-clock timestamps** (drift-free; resumes
    correctly across app sleep and quit/restart).
  - Gas math: completion accrual, **live real-time break drain**, negative
    overdraft to a configurable floor with auto-stop at the floor.
  - Diary ritual: `openDiary` / `completeDiary`, daily rollover (flush Gas,
    reset lap numbering — logs preserved).
  - Lap lifecycle: `startLap`, `cancelLap` (forfeit, earns/logs nothing),
    auto-complete on timeout with permanent logging + bell + banner.
  - `menuBarTitle` driving the dynamic menu bar label.
  - 250 ms ticker via a `Task` loop (Swift 6 friendly; no `Timer` closure
    isolation issues).
- **`NotificationManager.swift`** — `UNUserNotificationCenter` wrapper:
  authorization request, "lap complete" banner, and a `nonisolated` delegate so
  banners present even though the app is an `LSUIElement` agent.
- **`ContentView.swift`** (rewritten) — dropdown panel: diary open/close,
  Start Lap / Cancel lap, live lap countdown, live Gas balance (red when
  negative), Take/Stop Break, Diary Complete, Export Today's CSV…, Settings
  link, Quit.
- **`SettingsView.swift`** — ⌘, preferences (Settings scene): lap length,
  accrual %, overdraft floor, sound & banner toggles; live "earned per full
  lap" readout. Pushes changes to the engine immediately.
- **`LapWorkApp.swift`** (updated) — owns the single `TimerEngine`
  (`@StateObject`), injects it into both scenes, drives the dynamic
  `MenuBarExtra` label from `engine.menuBarTitle`, adds the `Settings` scene,
  and requests notification authorization at launch.
- **`CLAUDE.md`**, **`CHANGELOG.md`** — project context and history.

### Notes
- A real bell (`NSSound` "Glass"/"Ping") rings on lap completion when sound is
  enabled.
- Bell + banner each respect their own setting toggle.
- Builds clean under Swift 6 strict concurrency (no isolation warnings).

### Pre-existing (already in repo before this build)
- `MenuBarExtra` scene with `.menuBarExtraStyle(.window)`.
- `INFOPLIST_KEY_LSUIElement = YES` (agent app, no Dock icon).
