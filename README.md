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
`signal <name> on|off`, `pause <min>|tomorrow`, `resume`, `lock`, `unlock`, `sleep`, `wake`,
`displays-sleep`, `displays-wake`, `take eye|move|both`, `end-break`,
`credit eye|move|both|due`, `snooze`, `settings '<json patch>'`, `state`, `quit`.

## Time-away and restart policy

- **Work time** only accumulates during working hours while not paused, on a break, locked,
  asleep, displays asleep, or switched to another user. Meetings still count as work.
- **Returning from lock/sleep** credits each break type whose duration the time away covered
  (20s+ → eye, 2m+ → movement with defaults). Toggle: *Count locked or asleep time as a break*.
  Idle keyboard/mouse is never treated as a break. Returning gets the same grace period as a
  meeting ending, so an overdue break isn't announced the instant you unlock.
- **Sleep/clock jumps**: a tick more than 15s after the last is reconciled, never replayed.
- **Restarts**: timer state is saved every 15s and on every action/quit. A relaunch restores
  it; the time the app wasn't running counts as neither work nor a break. After 30+ minutes
  down, or on a new day, timers start fresh. Breaks already overdue wait out the grace period.
  Pause, Presentation mode, snooze and an in-progress break are restored too.

## Layout

| Path | Responsibility |
|---|---|
| `Model/BreakScheduler.swift` | Per-type accumulated work time and due state |
| `Model/ReminderCoordinator.swift` | Suppression, grace period, combining, repeat/snooze |
| `Model/AppModel.swift` | Tick loop and every user action (menu, notifications, ctl all call these) |
| `Model/Status.swift` | Status strings shown in the menu |
| `Model/TimerSnapshot.swift` | Saved timer state (`timers.json`) |
| `System/SystemEvents.swift` | Sleep, display sleep, screen lock, user switching |
| `Reminders/NotificationSink.swift` | Native notifications with Start / Snooze / Already took a break |
| `Control/TestControl.swift` | Test mode and the `ctl` client |
| `UI/` | Menu and settings window |

## Roadmap

1. ✅ Two timers, persistent settings, menu controls, manual Presentation mode, catch-up flow (simulated signals)
2. ✅ Sleep/wake, display sleep and lock handling; timer state persisted across restarts
3. Local detection: Core Audio mic-in-use (per process), camera in use
4. Optional full-screen break overlay, multi-display
