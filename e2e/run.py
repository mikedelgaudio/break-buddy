#!/usr/bin/env python3
"""End-to-end scenarios for Break Buddy.

Launches the real bundled app in test mode (manual clock, recorded reminders), drives it
through `BreakBuddy ctl`, and checks the state and event log it writes. Every run leaves
an artifact folder: e2e/artifacts/<stamp>/ with report.md, report.json, and per-scenario
events.jsonl / transcript.jsonl / settings.json. e2e/artifacts/latest points at it.

Usage: e2e/run.py [--no-build] [scenario-name ...]
"""

import json
import os
import subprocess
import sys
import time
import traceback
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "build" / "Break Buddy.app"
BIN = APP / "Contents" / "MacOS" / "BreakBuddy"
ARTIFACTS = ROOT / "e2e" / "artifacts"


class CheckFailed(Exception):
    pass


class App:
    """One test-mode app instance bound to a state directory."""

    def __init__(self, state_dir: Path):
        self.dir = state_dir
        self.dir.mkdir(parents=True, exist_ok=True)
        self.env = {**os.environ, "BB_TEST_MODE": "1", "BB_STATE_DIR": str(self.dir)}
        self.proc = None
        self.transcript = self.dir / "transcript.jsonl"

    def launch(self, start=None):
        """Starts the app; `start` (yyyy-MM-ddTHH:mm:ss) sets the clock, e.g. to simulate downtime."""
        (self.dir / "state.json").unlink(missing_ok=True)
        env = {**self.env, **({"BB_TEST_START": start} if start else {})}
        self.proc = subprocess.Popen([str(BIN)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.time() + 15
        while time.time() < deadline:
            try:
                if json.loads((self.dir / "state.json").read_text()).get("cmdId") == "launch":
                    return self
            except (FileNotFoundError, json.JSONDecodeError):
                pass
            time.sleep(0.05)
        raise RuntimeError("app did not report launch within 15s")

    def ctl(self, *args) -> dict:
        args = [str(a) for a in args]
        result = subprocess.run([str(BIN), "ctl", *args], env=self.env, capture_output=True, text=True, timeout=30)
        state = json.loads(result.stdout) if result.stdout.strip() else {}
        with self.transcript.open("a") as f:
            f.write(json.dumps({"cmd": args, "exit": result.returncode, "state": state}) + "\n")
        if result.returncode != 0:
            raise RuntimeError(f"ctl {' '.join(args)} failed ({result.returncode}): {state.get('error') or result.stderr.strip()}")
        return state

    def events(self, name=None) -> list:
        path = self.dir / "events.jsonl"
        events = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [e for e in events if name is None or e["event"] == name]

    def reminders(self) -> list:
        return self.events("reminder")

    def kill(self):
        """Hard kill (SIGKILL): no chance to save on the way out."""
        self.proc.kill()
        self.proc.wait(timeout=5)
        self.proc = None

    def quit(self):
        if self.proc and self.proc.poll() is None:
            try:
                self.ctl("quit")
            except Exception:
                pass
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.proc = None


class Checker:
    def __init__(self):
        self.checks = []

    def __call__(self, condition, description, actual=None):
        self.checks.append({"ok": bool(condition), "check": description, "actual": actual})
        if not condition:
            raise CheckFailed(f"{description} (actual: {actual!r})")

    def eq(self, actual, expected, description):
        self(actual == expected, f"{description} == {expected!r}", actual)

    def between(self, actual, low, high, description):
        self(low <= actual <= high, f"{low} <= {description} <= {high}", actual)


# ---------------------------------------------------------------------------
# Scenarios. Defaults: eye every 20m, movement every 50m, 60s grace, 5m snooze,
# working hours Mon–Fri 09:00–18:00, clock starts Monday 2026-10-26 09:00.

SCENARIOS = []


def scenario(fn):
    SCENARIOS.append(fn)
    return fn


@scenario
def eye_break_due_while_working(app, check):
    """An eye break comes due during normal work and is offered once, then repeated only after the snooze interval."""
    check.eq(app.ctl("advance", 1199)["remindersDelivered"], 0, "reminders at 19:59")
    s = app.ctl("advance", 1)
    check.eq([r["kinds"] for r in app.reminders()], [["eye"]], "reminder kinds at 20:00")
    check.eq(app.reminders()[0]["catchUp"], False, "first reminder is not a catch-up")
    check.eq(s["status"], "Eye break overdue", "status")
    check.eq(app.ctl("advance", 299)["remindersDelivered"], 1, "reminders while unanswered (< snooze interval)")
    check.eq(app.ctl("advance", 1)["remindersDelivered"], 2, "reminders after snooze interval")


@scenario
def presentation_defers_then_one_catch_up(app, check):
    """Breaks due during a 1h presentation are held, then offered as ONE combined catch-up after the grace period."""
    app.ctl("presentation", "on")
    s = app.ctl("advance", 3600)
    check.eq(s["remindersDelivered"], 0, "reminders during presentation")
    check.eq(s["status"], "Deferred · Presentation mode · Eye and movement breaks overdue", "status during presentation")
    app.ctl("presentation", "off")
    s = app.ctl("advance", 59)
    check.eq(s["remindersDelivered"], 0, "reminders during grace")
    check(s["status"].startswith("Catch-up break in"), "status shows catch-up countdown", s["status"])
    app.ctl("advance", 1)
    check.eq([r["kinds"] for r in app.reminders()], [["eye", "move"]], "single combined catch-up")
    check.eq(app.reminders()[0]["catchUp"], True, "reminder flagged as catch-up")
    check.eq(app.ctl("advance", 240)["remindersDelivered"], 1, "no backlog of missed intervals")


@scenario
def new_meeting_during_grace_cancels(app, check):
    """A new suppression reason during the grace period cancels the countdown and defers again."""
    app.ctl("presentation", "on")
    app.ctl("advance", 1300)
    app.ctl("presentation", "off")
    check.eq(app.ctl("advance", 30)["graceActive"], True, "grace running")
    app.ctl("signal", "call", "on")
    s = app.ctl("advance", 600)
    check.eq(s["remindersDelivered"], 0, "reminders after new meeting started in grace")
    check.eq(s["graceActive"], False, "grace cancelled")
    check.eq(s["status"], "Deferred · Simulated call · Eye break overdue", "status")
    app.ctl("signal", "call", "off")
    check.eq(app.ctl("advance", 59)["remindersDelivered"], 0, "fresh grace period is a full 60s")
    app.ctl("advance", 1)
    check.eq([r["kinds"] for r in app.reminders()], [["eye"]], "catch-up after second meeting")


@scenario
def share_ends_but_call_continues(app, check):
    """Screen sharing stops while the call continues: still deferred until every reason clears."""
    app.ctl("signal", "call", "on")
    app.ctl("signal", "share", "on")
    app.ctl("advance", 1300)
    app.ctl("signal", "share", "off")
    s = app.ctl("advance", 120)
    check.eq(s["remindersDelivered"], 0, "reminders after share ended")
    check.eq(s["suppression"], ["Simulated call"], "remaining suppression reasons")
    app.ctl("signal", "call", "off")
    app.ctl("advance", 60)
    check.eq(len(app.reminders()), 1, "one reminder after call ends + grace")


@scenario
def combined_reminder_when_both_due(app, check):
    """Eye and movement breaks due at the same time produce one combined reminder."""
    app.ctl("settings", json.dumps({"moveIntervalMinutes": 20}))
    app.ctl("advance", 1200)
    check.eq([r["kinds"] for r in app.reminders()], [["eye", "move"]], "reminders")


@scenario
def partial_break_leaves_movement_pending(app, check):
    """Completing only an eye break restarts the eye timer and leaves the movement break pending."""
    app.ctl("settings", json.dumps({"moveIntervalMinutes": 20}))
    app.ctl("advance", 1200)
    s = app.ctl("take", "eye")
    check.eq(s["activeBreak"]["kinds"], ["eye"], "active break kinds")
    check.eq(app.ctl("advance", 19)["activeBreak"]["kinds"], ["eye"], "break still running at 19s")
    s = app.ctl("advance", 1)
    check.eq([e["kinds"] for e in app.events("breakCompleted")], [["eye"]], "completed break kinds")
    check.eq(s["due"], ["move"], "still due")
    check.eq(s["worked"]["eye"], 0, "eye timer reset")
    check.eq(s["worked"]["move"], 1200, "movement time not accumulated during break")
    check.eq(app.ctl("advance", 279)["remindersDelivered"], 1, "movement not re-announced right after the break")
    app.ctl("advance", 1)
    check.eq([r["kinds"] for r in app.reminders()], [["eye", "move"], ["move"]], "movement reminder repeats alone")


@scenario
def snooze_holds_pending_breaks(app, check):
    """Snoozing keeps the break pending and offers it again after the snooze duration."""
    app.ctl("settings", json.dumps({"snoozeMinutes": 10}))
    app.ctl("advance", 1200)
    s = app.ctl("snooze")
    check.eq(s["snoozed"], True, "snoozed")
    check.eq(s["due"], ["eye"], "break still pending")
    check.eq(app.ctl("advance", 599)["remindersDelivered"], 1, "reminders during snooze")
    check.eq(app.ctl("advance", 1)["remindersDelivered"], 2, "reminders after snooze")


@scenario
def already_took_a_break_credits(app, check):
    """'Already took a break' credits the due types and restarts their timers."""
    app.ctl("advance", 1200)
    s = app.ctl("credit", "due")
    check.eq(s["due"], [], "nothing due after credit")
    check.eq(s["worked"]["eye"], 0, "eye timer reset")
    check.eq(s["worked"]["move"], 1200, "movement timer untouched")
    check(s["status"].startswith("Eyes in 20m"), "status shows fresh eye countdown", s["status"])
    check.eq(app.ctl("advance", 1199)["remindersDelivered"], 1, "reminders before next interval")
    check.eq(app.ctl("advance", 1)["remindersDelivered"], 2, "reminders at next interval")


@scenario
def manual_break_and_early_end(app, check):
    """A break from the menu credits its types when it finishes; ending early credits nothing."""
    app.ctl("advance", 600)
    app.ctl("take", "eye")
    s = app.ctl("end-break")
    check("activeBreak" not in s, "break ended", s.get("activeBreak"))
    check.eq(s["worked"]["eye"], 600, "early end gives no credit")
    app.ctl("take", "both")
    s = app.ctl("advance", 120)
    check.eq([e["kinds"] for e in app.events("breakCompleted")], [["eye", "move"]], "combined break completed")
    check.eq(s["worked"], {"eye": 0, "move": 0}, "both timers reset")


@scenario
def pause_stops_work_time(app, check):
    """Pausing for 15 minutes stops accumulation and resumes automatically."""
    s = app.ctl("pause", 15)
    check(s["status"].startswith("Paused until"), "status shows pause", s["status"])
    s = app.ctl("advance", 899)
    check.eq(s["worked"]["eye"], 0, "no work time while paused")
    app.ctl("advance", 1)
    check.eq(len(app.events("pauseEnded")), 1, "pause ended by itself")
    s = app.ctl("advance", 900)
    check.between(s["worked"]["eye"], 899, 901, "work time after resume")
    check.eq(s["remindersDelivered"], 0, "no reminders")


@scenario
def working_hours_only(app, check):
    """Time outside working hours and on weekends does not count."""
    app.ctl("set-time", "2026-10-26T17:50:00")
    s = app.ctl("advance", 1800)
    check.between(s["worked"]["eye"], 599, 601, "work time 17:50–18:00 only")
    check.eq(s["status"], "Outside working hours", "status")
    app.ctl("set-time", "2026-10-31T10:00:00")  # Saturday
    s = app.ctl("advance", 600)
    check.between(s["worked"]["eye"], 599, 601, "weekend adds nothing")
    check.eq(s["remindersDelivered"], 0, "no reminders")


@scenario
def clock_jump_does_not_burst(app, check):
    """Sleep or clock changes reconcile without replaying missed ticks or firing a burst."""
    app.ctl("advance", 600)
    s = app.ctl("set-time", "2026-10-26T14:00:00")
    check.eq(len(app.events("gap")), 1, "gap detected")
    check.eq(s["worked"]["eye"], 600, "jump forward not counted as work")
    check.eq(s["remindersDelivered"], 0, "no burst after jump")
    s = app.ctl("set-time", "2026-10-26T13:00:00")
    check.eq(s["worked"]["eye"], 600, "jump backward changes nothing")
    s = app.ctl("advance", 1)
    check.eq(s["worked"]["eye"], 601, "normal ticking resumes")


@scenario
def settings_persist_across_restart(app, check):
    """Settings survive quitting and relaunching the app."""
    app.ctl("settings", json.dumps({"eyeIntervalMinutes": 25, "graceSeconds": 90}))
    app.quit()
    app.launch()
    s = app.ctl("state")
    check.eq(s["settings"]["eyeIntervalMinutes"], 25, "eye interval after restart")
    check.eq(s["settings"]["graceSeconds"], 90, "grace after restart")
    check.eq(app.ctl("advance", 1499)["remindersDelivered"], 0, "no reminder before 25m")
    check.eq(app.ctl("advance", 1)["remindersDelivered"], 1, "reminder at 25m")


@scenario
def presentation_mode_expires(app, check):
    """Presentation mode with a 60-minute expiry turns itself off and then offers a catch-up."""
    app.ctl("presentation", "on", 60)
    check.eq(app.ctl("advance", 3599)["presentationMode"], True, "still presenting at 59:59")
    s = app.ctl("advance", 1)
    check.eq(s["presentationMode"], False, "expired at 60:00")
    check.eq(len(app.events("presentationEnded")), 1, "expiry event")
    check.eq(app.ctl("advance", 59)["remindersDelivered"], 0, "grace after expiry")
    app.ctl("advance", 1)
    check.eq([(r["kinds"], r["catchUp"]) for r in app.reminders()], [(["eye", "move"], True)], "catch-up after expiry")


# --- Milestone 2: away time (lock/sleep) and restarts ------------------------


@scenario
def lock_stops_work_and_credits_eye(app, check):
    """Locking stops work time; a 30s lock covers the 20s eye break but not the 2m movement break."""
    app.ctl("advance", 600)
    s = app.ctl("lock")
    check.eq(s["status"], "Away · Screen locked", "status while locked")
    s = app.ctl("advance", 30)
    check.eq(s["worked"]["eye"], 600, "no work time while locked")
    s = app.ctl("unlock")
    returned = app.events("returned")
    check.eq([(r["seconds"], r["credited"]) for r in returned], [(30, ["eye"])], "returned event")
    check.eq(s["worked"], {"eye": 0, "move": 600}, "eye credited, movement kept")


@scenario
def brief_lock_credits_nothing(app, check):
    """A lock shorter than any break duration credits nothing and loses no progress."""
    app.ctl("advance", 600)
    app.ctl("lock")
    app.ctl("advance", 10)
    s = app.ctl("unlock")
    check.eq(app.events("returned")[0]["credited"], [], "credited kinds")
    check.eq(s["worked"], {"eye": 600, "move": 600}, "work time kept")


@scenario
def long_lock_clears_overdue_breaks(app, check):
    """Stepping away (locked 3m) with both breaks overdue credits both; no reminder on return."""
    app.ctl("advance", 3000)
    before = app.ctl("state")["remindersDelivered"]
    check.eq(app.ctl("state")["due"], ["eye", "move"], "both overdue before lock")
    app.ctl("lock")
    app.ctl("advance", 180)
    s = app.ctl("unlock")
    check.eq(s["due"], [], "nothing due after return")
    check.eq(app.ctl("advance", 300)["remindersDelivered"], before, "no reminder after returning")


@scenario
def sleep_wake_waits_grace_without_credit(app, check):
    """With away-credit off, an overdue break survives sleep and waits out the grace period after wake."""
    app.ctl("settings", json.dumps({"creditTimeAway": False}))
    app.ctl("advance", 1300)
    check.eq(app.ctl("state")["remindersDelivered"], 1, "eye reminder before sleep")
    app.ctl("sleep")
    app.ctl("set-time", "2026-10-26T10:30:00")  # asleep: no ticks for ~68 minutes
    s = app.ctl("wake")
    check.eq(len(app.events("gap")), 1, "wake seen as a gap, not replayed")
    check.eq(s["worked"]["eye"], 1300, "sleep not counted as work")
    check.eq(s["due"], ["eye"], "eye still overdue")
    check.eq(app.ctl("advance", 59)["remindersDelivered"], 1, "no reminder during grace after wake")
    app.ctl("advance", 1)
    after = app.reminders()[1:]
    # 10:30 is t=5400; grace ends 60s after wake. Not a meeting catch-up, so no "meeting is over" text.
    check.eq([(r["kinds"], r["t"], r["catchUp"]) for r in after], [(["eye"], 5460, False)], "one reminder after grace")


@scenario
def wake_to_lock_screen_stays_away(app, check):
    """Waking to the lock screen is still away; return is counted from sleep until unlock."""
    app.ctl("advance", 600)
    app.ctl("lock")
    app.ctl("sleep")
    app.ctl("set-time", "2026-10-26T09:40:00")
    s = app.ctl("wake")
    check.eq(s["away"], ["Screen locked"], "still away after wake")
    check.eq(app.events("returned"), [], "no return yet")
    app.ctl("advance", 5)
    s = app.ctl("unlock")
    check.eq([(r["seconds"], r["credited"]) for r in app.events("returned")], [(1805, ["eye", "move"])], "returned event")
    check.eq(s["worked"], {"eye": 0, "move": 0}, "both credited")


@scenario
def display_sleep_counts_as_away(app, check):
    """Displays sleeping (idle long enough for the screen to turn off) stops work time."""
    app.ctl("advance", 600)
    app.ctl("displays-sleep")
    s = app.ctl("advance", 300)
    check.eq(s["worked"]["eye"], 600, "no work time with displays asleep")
    s = app.ctl("displays-wake")
    check.eq(s["worked"], {"eye": 0, "move": 0}, "5 minutes away credits both")


@scenario
def quick_restart_restores_timers(app, check):
    """Quitting and relaunching 5 minutes later restores progress; downtime is not work."""
    app.ctl("advance", 900)
    app.quit()
    app.launch(start="2026-10-26T09:20:00")
    s = app.ctl("state")
    check.eq(s["worked"], {"eye": 900, "move": 900}, "restored work time")
    check.eq([e["fresh"] for e in app.events("restored")], [False], "restored, not fresh")
    check.eq(app.ctl("advance", 299)["remindersDelivered"], 0, "eye not due yet")
    check.eq(app.ctl("advance", 1)["remindersDelivered"], 1, "eye due after 300 more working seconds")


@scenario
def overdue_after_restart_waits_grace(app, check):
    """Relaunching with a break already overdue does not remind instantly; it waits out the grace period."""
    app.ctl("advance", 1300)
    app.quit()
    app.launch(start="2026-10-26T09:23:00")
    s = app.ctl("state")
    check.eq(s["due"], ["eye"], "eye still overdue after restart")
    check.eq(s["graceActive"], True, "grace running at launch")
    check.eq(app.ctl("advance", 59)["remindersDelivered"], 0, "no reminder burst on launch")
    check.eq(app.ctl("advance", 1)["remindersDelivered"], 1, "one reminder after grace")


@scenario
def long_downtime_starts_fresh(app, check):
    """After 30+ minutes not running, or on a new day, timers start fresh."""
    app.ctl("advance", 900)
    app.quit()
    app.launch(start="2026-10-26T10:00:00")
    check.eq(app.ctl("state")["worked"], {"eye": 0, "move": 0}, "fresh after 45 min downtime")
    app.ctl("advance", 600)
    app.quit()
    app.launch(start="2026-10-27T09:00:30")
    check.eq(app.ctl("state")["worked"], {"eye": 0, "move": 0}, "fresh on a new day")
    check.eq([e["fresh"] for e in app.events("restored")], [True, True], "both restores fresh")


@scenario
def hard_kill_loses_at_most_15s(app, check):
    """A crash (SIGKILL) loses at most the 15s between periodic saves."""
    app.ctl("advance", 607)
    app.kill()
    app.launch(start="2026-10-26T09:11:00")
    check.between(app.ctl("state")["worked"]["eye"], 607 - 15, 607, "restored eye work time")


@scenario
def pause_and_presentation_survive_restart(app, check):
    """Pause and Presentation mode are restored after a relaunch."""
    app.ctl("presentation", "on")
    app.ctl("advance", 60)
    app.quit()
    app.launch(start="2026-10-26T09:02:00")
    s = app.ctl("state")
    check.eq(s["presentationMode"], True, "presentation restored")
    check(s["status"].startswith("Deferred · Presentation mode"), "status deferred", s["status"])
    app.ctl("presentation", "off")
    app.ctl("pause", 60)
    app.quit()
    app.launch(start="2026-10-26T09:05:00")
    s = app.ctl("state")
    check.eq(s["paused"], True, "pause restored")
    check(s["status"].startswith("Paused until"), "status paused", s["status"])


@scenario
def break_finished_while_not_running(app, check):
    """A break that would have ended while the app was closed is credited on relaunch."""
    app.ctl("advance", 600)
    app.ctl("take", "both")
    app.quit()
    app.launch(start="2026-10-26T09:15:00")
    s = app.ctl("state")
    check("activeBreak" not in s, "no active break", s.get("activeBreak"))
    check.eq(s["worked"], {"eye": 0, "move": 0}, "break credited")
    check.eq(len(app.events("breakCompleted")), 1, "completion recorded")


# --- Milestone 3: meeting detection (fake detector, real debounce/evidence path) ---
# The detector is polled every 2s; evidence must persist 5s to count and may vanish for
# 10s before it clears (then the 60s grace period starts). Expect a catch-up ~70–72s
# after the last signal disappears.

TEAMS = ("com.microsoft.teams2", "Microsoft Teams")


@scenario
def teams_mic_defers_then_catches_up(app, check):
    """Teams using the microphone defers an eye break; one catch-up arrives after the call, release delay and grace."""
    app.ctl("advance", 600)
    app.ctl("detect", "mic", *TEAMS, "on")
    s = app.ctl("advance", 10)
    check.eq(s["detection"]["active"], ["Microsoft Teams using microphone"], "evidence")
    s = app.ctl("advance", 800)
    check.eq(s["remindersDelivered"], 0, "no reminder during the call")
    check.eq(s["status"], "Deferred · Microsoft Teams using microphone · Eye break overdue", "status names the evidence")
    app.ctl("detect", "mic", *TEAMS, "off")
    check.eq(app.ctl("advance", 68)["remindersDelivered"], 0, "quiet through release delay + grace")
    app.ctl("advance", 6)
    check.eq([(r["kinds"], r["catchUp"]) for r in app.reminders()], [(["eye"], True)], "one catch-up")


@scenario
def brief_mic_blip_is_ignored(app, check):
    """A 3-second microphone blip never counts as a call."""
    app.ctl("advance", 10)
    app.ctl("detect", "mic", "com.example.voice", "Voice Memos", "on")
    app.ctl("advance", 3)
    app.ctl("detect", "mic", "com.example.voice", "Voice Memos", "off")
    s = app.ctl("advance", 30)
    check.eq(app.events("detection"), [], "no detection change")
    check.eq(s["suppression"], [], "nothing deferring")


@scenario
def mute_unmute_is_not_a_meeting_end(app, check):
    """Short and long mutes (mic input stopping) don't produce a reminder mid-call."""
    app.ctl("detect", "mic", *TEAMS, "on")
    app.ctl("advance", 1300)
    app.ctl("detect", "mic", *TEAMS, "off")      # muted 8s: within release delay
    app.ctl("advance", 8)
    app.ctl("detect", "mic", *TEAMS, "on")
    app.ctl("advance", 30)
    check.eq(len(app.events("detection")), 1, "short mute never cleared the evidence")
    app.ctl("detect", "mic", *TEAMS, "off")      # muted 40s: evidence clears, grace starts
    app.ctl("advance", 40)
    app.ctl("detect", "mic", *TEAMS, "on")       # unmute re-confirms within grace
    s = app.ctl("advance", 120)
    check.eq(s["detection"]["active"], ["Microsoft Teams using microphone"], "call evidence back")
    check.eq(s["remindersDelivered"], 0, "no reminder from mute/unmute")


@scenario
def dictation_and_ignored_apps_dont_defer(app, check):
    """Dictation (ignored by default) and a user-ignored app don't defer reminders but are listed as seen."""
    ignored = app.ctl("state")["settings"]["ignoredApps"] + ["com.example.recorder"]
    app.ctl("settings", json.dumps({"ignoredApps": ignored}))
    app.ctl("detect", "mic", "com.apple.CoreSpeech", "Dictation", "on")
    app.ctl("detect", "mic", "com.example.recorder", "Recorder", "on")
    s = app.ctl("advance", 1200)
    check.eq(s["suppression"], [], "nothing deferring")
    check.eq(s["remindersDelivered"], 1, "eye reminder delivered normally")
    check.eq(sorted(s["detection"]["seenMicApps"]), ["com.apple.CoreSpeech", "com.example.recorder"], "seen apps listed for the ignore UI")


@scenario
def camera_only_silent_attendee(app, check):
    """Camera on with the mic silent (attending quietly) still defers."""
    app.ctl("detect", "camera", "on")
    s = app.ctl("advance", 1300)
    check.eq(s["suppression"], ["Camera in use"], "evidence")
    check.eq(s["remindersDelivered"], 0, "no reminder")


@scenario
def mic_ends_but_camera_continues(app, check):
    """One signal ending while another continues keeps deferring; all clearing gives one catch-up."""
    app.ctl("detect", "mic", *TEAMS, "on")
    app.ctl("detect", "camera", "on")
    app.ctl("advance", 1300)
    app.ctl("detect", "mic", *TEAMS, "off")
    s = app.ctl("advance", 120)
    check.eq(s["suppression"], ["Camera in use"], "camera still deferring")
    check.eq(s["remindersDelivered"], 0, "no reminder")
    app.ctl("detect", "camera", "off")
    app.ctl("advance", 75)
    check.eq(len(app.reminders()), 1, "one catch-up after both clear")


@scenario
def unattributed_microphone(app, check):
    """Input running with no process to blame is still evidence, labelled honestly."""
    app.ctl("detect", "mic-unattributed", "on")
    check.eq(app.ctl("advance", 10)["detection"]["active"], ["Microphone in use"], "evidence label")


@scenario
def detection_can_be_turned_off(app, check):
    """With both detectors off, mic and camera activity are ignored and the menu says so."""
    app.ctl("settings", json.dumps({"detectMicrophone": False, "detectCamera": False}))
    app.ctl("detect", "mic", *TEAMS, "on")
    app.ctl("detect", "camera", "on")
    s = app.ctl("advance", 1200)
    check.eq(s["remindersDelivered"], 1, "reminder not deferred")
    check.eq(s["detection"]["status"], "Meeting detection off", "detection status")


@scenario
def detection_failure_shows_uncertainty(app, check):
    """Detector errors: status says unavailable, evidence is held for 5 minutes (not a fake meeting end), manual mode still works."""
    app.ctl("detect", "mic", *TEAMS, "on")
    app.ctl("advance", 600)
    app.ctl("detect", "fail", "Core Audio error")
    s = app.ctl("advance", 120)
    check.eq(s["detection"]["available"], False, "unavailable")
    check.eq(s["detection"]["status"], "Meeting detection unavailable", "detection status")
    check.eq(s["detection"]["active"], ["Microsoft Teams using microphone"], "evidence held during failure")
    s = app.ctl("advance", 200)
    check.eq(s["detection"]["active"], [], "evidence released after the hold limit")
    s = app.ctl("presentation", "on")
    check.eq(s["suppression"], ["Presentation mode"], "manual Presentation mode still works")
    app.ctl("detect", "ok")
    s = app.ctl("advance", 10)
    check.eq(len(app.events("detectionRestored")), 1, "recovery recorded")
    check.eq(s["suppression"], ["Microsoft Teams using microphone", "Presentation mode"], "evidence back after recovery")


@scenario
def hardware_probe(app, check):
    """The real Core Audio / CoreMediaIO detector works on this Mac and is cheap enough to poll every 2s."""
    result = subprocess.run([str(BIN), "probe", "6"], capture_output=True, text=True, timeout=30)
    probe = json.loads(result.stdout)
    (app.dir / "probe.json").write_text(json.dumps(probe, indent=2))
    check.eq(probe["available"], True, "detector available")
    warm = sorted(probe["timingsMs"][1:])
    check(warm[len(warm) // 2] < 25, "median warm read < 25ms", round(warm[len(warm) // 2], 2))
    check(all(sig["kind"] in ("microphone", "camera") and sig["label"] for sig in probe["signals"]), "signals well-formed", probe["signals"])


# --- Presence: your input vs agents (fake input monitor) ------------------------
# By default the fake reports you as always active. `input human` records a keyboard/mouse
# event now; `input agent` is activity that doesn't touch the hardware idle clock.


@scenario
def agent_activity_is_not_you(app, check):
    """Agents keeping the Mac busy don't count as you: after 3 min without your input you're away, idle work is refunded, and coming back credits the break."""
    app.ctl("advance", 600)
    app.ctl("input", "human")
    for _ in range(10):
        app.ctl("input", "agent")
        app.ctl("advance", 30)
    s = app.ctl("state")
    check.eq(s["away"], ["No input from you"], "away after 3 min without your input")
    check.eq(s["status"], "Away · No input from you", "status")
    check.eq(s["worked"]["eye"], 600, "the idle minutes are refunded")
    check.eq(len(app.events("agentActivity")), 10, "agent activity happened throughout")
    s = app.ctl("advance", 300)
    check.eq(s["worked"]["eye"], 600, "no work time while away")
    check.eq(s["remindersDelivered"], 0, "no reminder to an empty chair")
    app.ctl("input", "human")
    s = app.ctl("advance", 1)
    returned = app.events("returned")
    check.eq([r["credited"] for r in returned], [["eye", "move"]], "time away credited")
    check.between(returned[0]["seconds"], 600, 602, "away time measured from your last input")
    check.eq(s["worked"], {"eye": 0, "move": 0}, "timers restart")


@scenario
def watching_a_meeting_without_input_still_counts(app, check):
    """No input during a call means watching, not away: work time keeps counting and reminders stay deferred."""
    app.ctl("input", "human")
    app.ctl("detect", "mic", *TEAMS, "on")
    s = app.ctl("advance", 1300)
    check.eq(s["away"], [], "not away during the meeting")
    check.between(s["worked"]["eye"], 1299, 1300, "meeting time counts as screen time")
    check.eq(s["remindersDelivered"], 0, "reminder deferred")


@scenario
def short_pause_is_not_away(app, check):
    """Reading for 2½ minutes without touching anything doesn't count as stepping away."""
    app.ctl("input", "human")
    app.ctl("advance", 150)
    app.ctl("input", "human")
    s = app.ctl("advance", 150)
    check.eq(app.events("awayBegan"), [], "never away")
    check.eq(s["worked"]["eye"], 300, "all of it counted as work")


@scenario
def return_from_idle_waits_before_reminding(app, check):
    """With away-credit off, an overdue break waits out the grace countdown after you come back."""
    app.ctl("settings", json.dumps({"creditTimeAway": False, "snoozeMinutes": 30}))
    app.ctl("advance", 1300)
    app.ctl("input", "human")
    s = app.ctl("advance", 180)
    check.eq(s["away"], ["No input from you"], "away")
    check.eq(s["worked"]["eye"], 1300, "idle stretch refunded")
    app.ctl("advance", 600)
    app.ctl("input", "human")
    s = app.ctl("advance", 1)
    check.eq(s["due"], ["eye"], "eye still overdue (no credit)")
    check.eq(app.ctl("advance", 58)["remindersDelivered"], 1, "no reminder right after you return")
    app.ctl("advance", 2)
    after = app.reminders()[1:]
    check.eq([(r["kinds"], r["catchUp"]) for r in after], [(["eye"], False)], "one reminder after the countdown")


@scenario
def idle_threshold_is_configurable(app, check):
    """The away-after setting is respected (2 minutes here)."""
    app.ctl("settings", json.dumps({"idleMinutes": 2}))
    app.ctl("input", "human")
    check.eq(app.ctl("advance", 119)["away"], [], "present at 1:59")
    check.eq(app.ctl("advance", 1)["away"], ["No input from you"], "away at 2:00")



@scenario
def watching_video_is_screen_time(app, check):
    """A video playing with no input is watching, not away: work time counts and the eye reminder still arrives."""
    app.ctl("input", "human")
    app.ctl("video", "on", "Google Chrome")
    s = app.ctl("advance", 1300)
    check.eq(s["watching"], ["Google Chrome"], "video evidence")
    check.eq(s["away"], [], "never away while the video plays")
    check.between(s["worked"]["eye"], 1299, 1300, "video time counts as screen time")
    check.eq([(r["kinds"], int(r["t"])) for r in app.reminders()], [(["eye"], 1200)], "eye reminder on schedule (video isn't a meeting)")


@scenario
def video_ends_then_you_leave(app, check):
    """After a video ends, away is measured from the end of the video, not from your last input before it."""
    app.ctl("input", "human")
    app.ctl("video", "on", "Google Chrome")
    app.ctl("advance", 600)
    app.ctl("video", "off", "Google Chrome")
    check.eq(app.ctl("advance", 179)["away"], [], "present 2:59 after the video ended")
    s = app.ctl("advance", 3)
    check.eq(s["away"], ["No input from you"], "away 3 min after the video ended")
    check.between(s["worked"]["eye"], 600, 602, "only time after the video is refunded")
    app.ctl("advance", 118)
    app.ctl("input", "human")
    app.ctl("advance", 1)
    returned = app.events("returned")
    check.between(returned[0]["seconds"], 299, 303, "away time counted from the end of the video")
    check.eq(returned[0]["credited"], ["eye", "move"], "natural break credited")


@scenario
def drink_break_is_credited(app, check):
    """Leaving the keyboard for 3+ minutes (getting a drink) counts as a natural break, measured from when you left."""
    app.ctl("advance", 600)
    app.ctl("input", "human")
    app.ctl("advance", 200)
    app.ctl("input", "human")
    s = app.ctl("advance", 1)
    returned = app.events("returned")
    check.eq([r["credited"] for r in returned], [["eye", "move"]], "both breaks credited")
    check.between(returned[0]["seconds"], 200, 202, "away from the moment you left")
    check.eq(s["worked"], {"eye": 0, "move": 0}, "timers restart")
    check.eq(s["remindersDelivered"], 0, "no reminder")


@scenario
def keep_awake_tools_are_not_watching(app, check):
    """`caffeinate` and similar keep-awake tools (often run by agents) don't count as watching."""
    app.ctl("input", "human")
    app.ctl("video", "on", "caffeinate")
    s = app.ctl("advance", 180)
    check.eq(s["watching"], [], "caffeinate ignored")
    check.eq(s["away"], ["No input from you"], "away as usual")


# --- Visual: menu bar stability, settings layout, app icon ------------------


@scenario
def menu_bar_width_is_stable(app, check):
    """The menu-bar item keeps one width for the whole countdown and the whole break timer (no jank)."""
    widths = {}
    s = app.ctl("state")
    for step in [60] * 19 + [10] * 5 + [1] * 9:   # 19m … 1m, then 50s … 10s, then 9s … 1s
        s = app.ctl("advance", step)
        if s["menuBar"][1]:
            widths[s["menuBar"][1]] = s["menuBarWidth"]
    app.ctl("render", "menubar", app.dir / "menubar-countdown.png")
    check(len(widths) >= 20, "sampled many countdown values", sorted(widths))
    check.eq(len(set(widths.values())), 1, "distinct widths during countdown")
    app.ctl("credit", "both")
    app.ctl("take", "move")  # 120s break
    break_widths = {}
    for _ in range(60):
        s = app.ctl("advance", 2)
        if s.get("activeBreak"):
            break_widths[s["menuBar"][1]] = s["menuBarWidth"]
    app.ctl("render", "menubar", app.dir / "menubar-break.png")
    check(len(break_widths) >= 30, "sampled the break timer", len(break_widths))
    check.eq(len(set(break_widths.values())), 1, "distinct widths during break")


@scenario
def settings_panes_are_wide_and_short(app, check):
    """Each settings pane renders at 600pt wide and stays under 480pt tall, in light and dark mode."""
    app.ctl("detect", "mic", *TEAMS, "on")
    app.ctl("advance", 2)
    for pane in ["breaks", "meetings", "schedule", "general"]:
        for mode in ["light", "dark"]:
            path = app.dir / f"settings-{pane}-{mode}.png"
            s = app.ctl("render", "settings", pane, path, *(["dark"] if mode == "dark" else []))
            width, height = s["renderSize"]
            check(path.exists() and path.stat().st_size > 10_000, f"{pane}/{mode} rendered", path.name)
            check.eq(width, 600, f"{pane}/{mode} width")
            check(height < 480, f"{pane}/{mode} height < 480", height)


@scenario
def app_icon_is_bundled(app, check):
    """The bundle declares and ships AppIcon.icns with a 1024px (512@2x) representation."""
    plist = subprocess.run(["plutil", "-extract", "CFBundleIconFile", "raw", str(APP / "Contents" / "Info.plist")], capture_output=True, text=True)
    check.eq(plist.stdout.strip(), "AppIcon", "CFBundleIconFile")
    icns = APP / "Contents" / "Resources" / "AppIcon.icns"
    check(icns.exists(), "AppIcon.icns in bundle", str(icns))
    out = app.dir / "AppIcon.iconset"
    subprocess.run(["iconutil", "-c", "iconset", str(icns), "-o", str(out)], check=True)
    check((out / "icon_512x512@2x.png").exists(), "1024px representation", sorted(p.name for p in out.iterdir()))
    subprocess.run(["cp", str(out / "icon_128x128@2x.png"), str(app.dir / "app-icon.png")], check=True)


# ---------------------------------------------------------------------------


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if "--no-build" not in sys.argv:
        subprocess.run([str(ROOT / "scripts" / "bundle.sh"), "debug"], check=True, stdout=subprocess.DEVNULL)

    selected = [s for s in SCENARIOS if not args or s.__name__ in args]
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    run_dir = ARTIFACTS / stamp
    run_dir.mkdir(parents=True)
    commit = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip() or "uncommitted"

    results = []
    for fn in selected:
        app = App(run_dir / fn.__name__)
        check = Checker()
        started = time.time()
        error = None
        try:
            app.launch()
            fn(app, check)
        except CheckFailed as e:
            error = str(e)
        except Exception:
            error = traceback.format_exc()
        finally:
            app.quit()
        results.append({
            "scenario": fn.__name__,
            "description": fn.__doc__.strip(),
            "passed": error is None,
            "error": error,
            "seconds": round(time.time() - started, 2),
            "checks": check.checks,
            "reminders": app.reminders(),
            "images": sorted(str(p.relative_to(run_dir)) for p in app.dir.glob("*.png")),
        })
        print(f"{'PASS' if error is None else 'FAIL'}  {fn.__name__}" + (f"\n      {error}" if error else ""))

    passed = sum(r["passed"] for r in results)
    summary = {"run": stamp, "commit": commit, "passed": passed, "total": len(results), "results": results}
    (run_dir / "report.json").write_text(json.dumps(summary, indent=2))
    (run_dir / "report.md").write_text(render_markdown(summary))
    latest = ARTIFACTS / "latest"
    latest.unlink(missing_ok=True)
    latest.symlink_to(stamp)
    print(f"\n{passed}/{len(results)} scenarios passed · report: {run_dir / 'report.md'}")
    sys.exit(0 if passed == len(results) else 1)


def render_markdown(summary):
    lines = [
        f"# Break Buddy E2E report",
        "",
        f"Run `{summary['run']}` · commit `{summary['commit']}` · **{summary['passed']}/{summary['total']} passed**",
        "",
        "Simulated clock starts Monday 2026-10-26 09:00. Defaults: eye 20m/20s, movement 50m/120s, grace 60s, snooze 5m.",
        "",
        "| Result | Scenario | Checks | Reminders delivered (t = simulated seconds) |",
        "|---|---|---|---|",
    ]
    for r in summary["results"]:
        reminders = ", ".join(f"{'+'.join(x['kinds'])}{' (catch-up)' if x['catchUp'] else ''} @ {int(x['t'])}s" for x in r["reminders"]) or "none"
        ok = sum(c["ok"] for c in r["checks"])
        lines.append(f"| {'✅' if r['passed'] else '❌'} | **{r['scenario']}** — {r['description']} | {ok}/{len(r['checks'])} | {reminders} |")
    for r in summary["results"]:
        lines += ["", f"## {r['scenario']}", "", r["description"], ""]
        lines += [f"- {'✅' if c['ok'] else '❌'} {c['check']}" + ("" if c["ok"] else f" — actual `{c['actual']!r}`") for c in r["checks"]]
        if r.get("images"):
            lines += [""] + [f"![{Path(i).stem}]({i})" for i in r["images"]]
        if r["error"] and not r["checks"] or (r["error"] and r["checks"][-1]["ok"]):
            lines += ["", "```", r["error"].strip(), "```"]
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    main()
