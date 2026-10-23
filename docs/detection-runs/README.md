# Detection runs

Real-call captures from `BreakBuddy probe --watch` (raw readings, polled every 0.5s, no
debounce). Each log line is a change; `evidence` is what the detector saw at that moment.

## 2026-10-22 · Google Meet in Chrome · macOS 27.0.1 · MacBook Pro

Log: [2026-10-22-chrome-meet.log](2026-10-22-chrome-meet.log). Steps were done by hand
(join, mute, camera off, share, leave) without recording when each step happened, so the
mapping below is inferred from the log.

| Time | Raw reading | Reading |
|---|---|---|
| 21:26:07.4 | + Google Chrome using microphone | Joined. Helper process correctly attributed to **Google Chrome** |
| 21:26:07.9 | audio out: Google Chrome | Call audio starts |
| 21:26:09.5–14.1 | Camera in use (4.6s) | Camera on, then turned off |
| 21:26:19.8–20.3 | Camera in use (0.5s) | Brief camera blip, e.g. during sharing or a toggle; filtered by the 5s onset |
| 21:26:07.4–37.9 | Microphone continuous (30.5s) | **Mic input never stopped**, including while muted and while sharing |
| 21:26:37.9 / 38.9 | − microphone, audio out: none | Left the call; everything cleared within 1s |

### Findings

1. **Helper → app mapping works.** `com.google.Chrome.helper` is reported as Google Chrome.
2. **Muting in Meet doesn't stop mic input.** The mic signal was continuous for the whole
   call, so mute/unmute is not a meeting-end event for browser calls. Mic + camera off
   (the "silent attendee") was still covered by the mic signal.
3. **Screen sharing added no evidence of its own**, as expected; the call's mic signal
   covered it.
4. **The camera turns off immediately.** It shows only while actually on; the 0.5s blip
   confirms the onset filter is needed.
5. **Chrome audio output lasted exactly as long as the call** (07.9 → 38.9). It's a possible
   extra signal, but Chrome also plays audio for ordinary media, so it can only be trusted
   per app (e.g. a meeting app like Teams), not for browsers.
6. **The end of the call is clean.** With the 10s release delay and 60s grace period, a
   catch-up would arrive about 70s after leaving.

### Still open

- Teams **desktop** (`com.microsoft.teams2`) mute behaviour and helper mapping: run
  `probe --watch` on a work Mac during a real call.
- A longer run with ~20s per step and noted times, to confirm the step mapping above.
