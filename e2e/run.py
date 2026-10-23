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

    def launch(self):
        (self.dir / "state.json").unlink(missing_ok=True)
        self.proc = subprocess.Popen([str(BIN)], env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
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
        if r["error"] and not r["checks"] or (r["error"] and r["checks"][-1]["ok"]):
            lines += ["", "```", r["error"].strip(), "```"]
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    main()
