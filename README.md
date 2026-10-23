# Break Buddy

A meeting-aware break reminder for the macOS menu bar. Separate eye and movement timers;
breaks that come due during a meeting or presentation are held and offered as **one**
catch-up break after the meeting ends and a short grace period passes.

## Build & run

No Xcode project — SwiftPM plus a bundling script (Xcode's toolchain is still required).

```bash
scripts/bundle.sh            # release build → build/Break Buddy.app
open "build/Break Buddy.app"
```

`swift build` alone compiles, but notifications and launch-at-login need the signed `.app`.

## E2E tests

```bash
e2e/run.py                   # builds, runs every scenario
e2e/run.py --no-build presentation_defers_then_one_catch_up
```

The harness launches the real app with `BB_TEST_MODE=1`: the clock only moves when told,
reminders are recorded instead of posted, and the app accepts `BreakBuddy ctl <command>`
over a distributed notification scoped to `BB_STATE_DIR`. Each run writes
`e2e/artifacts/<stamp>/report.md` (plus `report.json`, per-scenario `events.jsonl` and
`transcript.jsonl`); `e2e/artifacts/latest` points at the newest run.

Control commands: `advance <sec>`, `set-time <yyyy-MM-ddTHH:mm:ss>`, `presentation on|off [min]`,
`signal <name> on|off`, `pause <min>|tomorrow`, `resume`, `take eye|move|both`, `end-break`,
`credit eye|move|both|due`, `snooze`, `settings '<json patch>'`, `state`, `quit`.

## Layout

| Path | Responsibility |
|---|---|
| `Model/BreakScheduler.swift` | Per-type accumulated work time and due state |
| `Model/ReminderCoordinator.swift` | Suppression, grace period, combining, repeat/snooze |
| `Model/AppModel.swift` | Tick loop and every user action (menu, notifications, ctl all call these) |
| `Model/Status.swift` | Status strings shown in the menu |
| `Reminders/NotificationSink.swift` | Native notifications with Start / Snooze / Already took a break |
| `Control/TestControl.swift` | Test mode and the `ctl` client |
| `UI/` | Menu and settings window |

## Roadmap

1. ✅ Two timers, persistent settings, menu controls, manual Presentation mode, catch-up flow (simulated signals)
2. Sleep/wake and lock handling via NSWorkspace notifications; persist timer state across restarts
3. Local detection: Core Audio mic-in-use (per process), camera in use
4. Optional full-screen break overlay, multi-display
