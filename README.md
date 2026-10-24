# Break Buddy

A meeting-aware break reminder for the macOS menu bar. Separate eye and movement timers;
breaks that come due during a meeting or presentation are held and offered as **one**
catch-up break after the meeting ends and a short grace period passes.

## Install on another Mac

Requires macOS 15 or later; the DMG is universal (Apple silicon and Intel).

**Easiest: download with `gh`** (no Gatekeeper prompt, because command-line downloads aren't quarantined):

```bash
gh release download --repo mikedelgaudio/break-buddy --pattern '*.dmg' --dir ~/Downloads
```

Open the DMG and drag **Break Buddy** onto **Applications**.

**From the browser:** signed in to GitHub, open the repo → Releases → download the DMG, then drag
to Applications. The app isn't notarized, so the first launch is blocked: open **System Settings →
Privacy & Security**, scroll to *"Break Buddy" was blocked*, click **Open Anyway**. (Or run
`xattr -dr com.apple.quarantine "/Applications/Break Buddy.app"`.)

On a managed work Mac, unsigned apps may be blocked by policy — check before working around it.

### Making a release

Automatic: every push to `main` that touches the app (not just `*.md`, `docs/` or `design/`)
releases a **minor** bump via GitHub Actions ([.github/workflows/release.yml](.github/workflows/release.yml)).
It runs the full E2E suite on a macOS runner and, only if every scenario passes, builds the
universal DMG, tags the commit and publishes the release. The E2E report is attached to each run.

Manual runs pick their own bump:

```bash
gh workflow run release.yml -f bump=patch           # or minor / major; also a button in the Actions tab
gh workflow run release.yml -f bump=patch -f dry_run=true   # build + test only, DMG as a run artifact
```

Pushing a `v*` tag yourself also triggers it. Locally, `scripts/make-dmg.sh` builds the same DMG.

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
`displays-sleep`, `displays-wake`, `detect mic <bundleID> <name> on|off`, `detect mic-unattributed on|off`,
`detect camera on|off`, `detect fail <message>`, `detect ok`, `input human|agent|present`,
`render menubar <png>`, `render settings breaks|meetings|schedule|general <png> [dark]`, `take eye|move|both`, `end-break`,
`credit eye|move|both|due`, `snooze`, `settings '<json patch>'`, `state`, `quit`.

## Time-away and restart policy

- **Work time** only accumulates during working hours while not paused, on a break, locked,
  asleep, displays asleep, switched to another user, or idle. Meetings still count as work.
- **You vs. agents**: presence comes from the HID system's idle time — physical keyboard,
  mouse and trackpad only. Agents that keep the Mac awake and busy without posting input
  (terminals, builds, in-page browser automation) don't count as you. After 3 minutes
  (configurable) without your input you're away — long enough that getting a drink counts as
  a natural break. The away time is backdated to your last input and the work counted in
  between is refunded.
- **Watching counts as screen time**: during a meeting or presentation, or while an app keeps
  the display awake for video (Chrome's "Video Wake Lock", Safari, QuickTime — read from power
  assertions, no permission), no input means watching, never away. Idle is then measured from
  the end of the video or meeting. Agents' keep-awake uses system-sleep assertions and
  `caffeinate`-style tools are ignored, so neither looks like watching. Caveat: tools that post synthetic HID
  events with Accessibility permission (computer-use agents, mouse jigglers) may still look
  like you.
- **Returning from lock/sleep/idle** credits each break type whose duration the time away covered
  (20s+ → eye, 2m+ → movement with defaults). Toggle: *Count locked or asleep time as a break*.
  Idle keyboard/mouse is never treated as a break. Returning gets the same grace period as a
  meeting ending, so an overdue break isn't announced the instant you unlock.
- **Sleep/clock jumps**: a tick more than 15s after the last is reconciled, never replayed.
- **Restarts**: timer state is saved every 15s and on every action/quit. A relaunch restores
  it; the time the app wasn't running counts as neither work nor a break. After 30+ minutes
  down, or on a new day, timers start fresh. Breaks already overdue wait out the grace period.
  Pause, Presentation mode, snooze and an in-progress break are restored too.

## Meeting detection

Polls every 2s, no permission prompts:

- **Microphone, per app** — Core Audio process objects (`kAudioProcessPropertyIsRunningInput`,
  macOS 14.4+). Helper processes map to their parent app (`com.google.Chrome.helper` → Chrome).
  If input is running but no process claims it, the evidence is just "Microphone in use".
- **Camera** — CoreMediaIO `kCMIODevicePropertyDeviceIsRunningSomewhere` on any video device.
  Not attributable to an app.

The status shows what was actually observed — `Deferred · Microsoft Teams using microphone` —
never an inferred "Teams meeting". Evidence must persist 5s to count (blips are ignored) and
may vanish for up to 10s before it clears (short mutes), then the normal 60s grace applies, so
a longer mute that ends within the grace period also never produces a reminder. If the detector
errors, the menu says *Meeting detection unavailable* and existing evidence is held for up to
5 minutes rather than treated as a meeting end. Dictation, Siri and sound recognition are ignored
by default; any app seen using the mic can be ignored from Settings.

Not detected: screen sharing on its own. A Meet call in Chrome kept mic input running while
muted (see [docs/detection-runs](docs/detection-runs/README.md)); Teams desktop is still
unverified, so Presentation mode stays available. Check the real detector any time with:

```bash
"build/Break Buddy.app/Contents/MacOS/BreakBuddy" probe            # one JSON snapshot
"build/Break Buddy.app/Contents/MacOS/BreakBuddy" probe --watch    # timestamped change log
```

## App icon

`design/icon/artwork.png` is full-bleed artwork generated with Codex: resting eyes, chosen
over a wide-open eye that felt like surveillance. Other candidates are in `design/icon/` and
`design/icon/round-2/` (with `icon-options.png` comparing them). `scripts/make-icon.sh` applies the macOS icon grid, mask and shadow and
writes `Resources/AppIcon.icns`, which `bundle.sh` copies into the app.

## Layout

| Path | Responsibility |
|---|---|
| `Model/BreakScheduler.swift` | Per-type accumulated work time and due state |
| `Model/ReminderCoordinator.swift` | Suppression, grace period, combining, repeat/snooze |
| `Model/AppModel.swift` | Tick loop and every user action (menu, notifications, ctl all call these) |
| `Model/Status.swift` | Status strings shown in the menu |
| `Model/TimerSnapshot.swift` | Saved timer state (`timers.json`) |
| `Detection/CoreAudioDetector.swift` | Real mic-per-process and camera readings |
| `Detection/ActivitySignal.swift` | Evidence types, detector protocol, fake detector for E2E |
| `Detection/DetectionProbe.swift` | `BreakBuddy probe` diagnostic |
| `System/SystemEvents.swift` | Sleep, display sleep, screen lock, user switching |
| `Reminders/NotificationSink.swift` | Native notifications with Start / Snooze / Already took a break |
| `Control/TestControl.swift` | Test mode and the `ctl` client |
| `UI/MenuBarIcon.swift` | Fixed-width menu-bar label image (no jank as the countdown ticks) |
| `UI/` | Menu and tabbed settings window |

## Roadmap

1. ✅ Two timers, persistent settings, menu controls, manual Presentation mode, catch-up flow (simulated signals)
2. ✅ Sleep/wake, display sleep and lock handling; timer state persisted across restarts
3. ✅ Local detection: Core Audio mic-in-use (per process), camera in use
4. Validate against real Teams calls (muted, camera off, sharing); tune delays
5. Optional full-screen break overlay, multi-display
