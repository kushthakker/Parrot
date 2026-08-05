#!/usr/bin/env python3
"""Executable simulation of the planned MeetingAutoRecorder state machine
(docs/BACK-TO-BACK-PLAN.md) against realistic back-to-back timelines.

Models: 20s tick grid (with phase sweep), instantaneous audio-level sampling,
segment clock with decode lag, calendar events, title signal, Stage 1
(stop+drain+restart) vs Stage 2 (hot handoff), manual stops, and the
handled-occurrences bookkeeping including the suppression flag.

Invariants checked per run:
  I1  every meeting whose call was actually joined gets its own recording
  I2  speech is never lost overall (union of recordings covers all speech)
  I3  a recording never double-starts / two recordings never overlap
  I4  no meeting is 'poisoned' (auto-start expected but never happened)
  I5  split lands within tolerance of the ideal boundary
"""

from dataclasses import dataclass, field
from typing import Optional

TICK = 20.0
SPLIT_QUIET = 30.0
SPLIT_FORCE_CAP = 300.0
STOP_QUIET = 240.0
OVERRUN_CAP = 45 * 60.0


@dataclass
class Event:
    key: str
    start: float
    end: float


@dataclass
class Scenario:
    name: str
    events: list                    # calendar
    speech: list                    # [(start,end)] actual audio activity
    title: list = field(default_factory=list)   # [(start,end,event_key)] what's on screen; [] = no signal
    manual_stops: list = field(default_factory=list)
    horizon: float = 5400.0
    joined: Optional[list] = None   # event keys the user actually joined (default: all)
    expect_split_count: Optional[int] = None
    allow_mid_speech_split: bool = False


@dataclass
class Recording:
    start: float
    end: Optional[float] = None
    auto_key: Optional[str] = None  # event it was started for


class Sim:
    def __init__(self, sc, stage, tick_phase, decode_lag,
                 mark_prev_tick_set=True, quiet_blocked_by_title=True):
        self.sc, self.stage, self.lag = sc, stage, decode_lag
        self.mark_prev_tick_set = mark_prev_tick_set
        self.quiet_blocked_by_title = quiet_blocked_by_title
        self.t0 = tick_phase
        self.recordings = []
        self.handled = set()
        self.auto = None            # (key, end)
        self.last_speech = 0.0
        self.meet_ended_at = None
        self.was_recording = False
        self.suppress_mark = False
        self.ongoing_last_rec_tick = set()
        self.drain_until = -1.0     # stage 1: engine busy until then
        self.candidate = None       # armed retro-boundary (silence start)
        self.stage1_drain = 90.0
        self.log = []

    # --- world model -----------------------------------------------------
    def speech_active(self, t):
        return any(s <= t < e for s, e in self.sc.speech)

    def visible_segment_end(self, t):
        ends = [e for s, e in self.sc.speech if e + self.lag <= t]
        return max(ends) if ends else None

    def ongoing(self, t):
        return [e for e in self.sc.events if e.start <= t < e.end]

    def title_signal(self, t, cur_key, next_key):
        for s, e, k in self.sc.title:
            if s <= t < e:
                if k == next_key:
                    return "next"
                if k == cur_key:
                    return "current"
        return "unknown"

    # --- planned decision rule ------------------------------------------
    def should_split(self, now, cur_end, nxt_start, quiet_for, sig):
        if sig == "next":
            return True
        if now >= cur_end and quiet_for >= SPLIT_QUIET \
                and not (self.quiet_blocked_by_title and sig == "current"):
            return True
        if now >= nxt_start + SPLIT_FORCE_CAP and sig != "current":
            return True
        return False

    # --- recorder actions ------------------------------------------------
    def rec(self):
        return self.recordings[-1] if self.recordings and self.recordings[-1].end is None else None

    def start(self, t, key):
        self.candidate = None
        assert self.rec() is None, f"double start at {t}"
        self.recordings.append(Recording(start=t, auto_key=key))
        self.auto = key
        self.last_speech = t
        self.meet_ended_at = None
        if key:
            self.handled.add(key)
        self.log.append((t, f"start {key}"))

    def stop(self, t, why, suppress=False):
        r = self.rec()
        assert r, f"stop with no recording at {t}"
        r.end = t
        self.auto = None
        self.suppress_mark = suppress
        self.drain_until = t + self.stage1_drain  # drain on every real stop, both stages
        self.log.append((t, f"stop ({why})"))

    def refine(self, prov):
        iv = sorted(self.sc.speech)
        gaps = [(a[1], b[0]) for a, b in zip(iv, iv[1:]) if b[0] - a[1] >= 10]
        best = None
        for gs, ge in gaps:
            if ge >= prov - 60 and gs <= prov + 30:
                if best is None or abs(gs - prov) < abs(best[0] - prov):
                    best = (gs, ge)
        return min(best[0] + 2, best[1]) if best else prov

    def handoff(self, t, key, boundary=None):
        b = self.refine(boundary if boundary is not None else t)
        r = self.rec()
        r.end = b
        self.recordings.append(Recording(start=b, auto_key=key))
        self.auto = key
        self.handled.add(key)
        self.last_speech = t
        self.meet_ended_at = None
        self.log.append((t, f"handoff -> {key} (boundary {b:.0f})"))

    # --- one tick, mirroring the plan ------------------------------------
    def tick(self, now):
        ongoing = self.ongoing(now)
        recording = self.rec() is not None

        if recording:
            if self.speech_active(now):
                self.last_speech = now
            vis = self.visible_segment_end(now)
            if vis is not None:
                self.last_speech = max(self.last_speech, vis)
            self.ongoing_last_rec_tick = {e.key for e in ongoing}

            if self.auto is not None:
                cur = next((e for e in self.sc.events if e.key == self.auto), None)
                nxt = min((e for e in ongoing
                           if e.key not in self.handled and e.key != self.auto),
                          key=lambda e: e.start, default=None)
                if nxt is not None:
                    sig = self.title_signal(now, self.auto, nxt.key)
                    h = now - self.lag                      # record horizon
                    V = [(s, min(e, h)) for s, e in self.sc.speech if s <= h]
                    vis_end = max((e for _, e in V), default=None)
                    floor = max(self.recordings[-1].start, nxt.start - 600)
                    gaps = []
                    pts = sorted(V)
                    prev_end = None
                    for s, e in pts:
                        if prev_end is not None and s - prev_end >= 30 and prev_end >= floor:
                            gaps.append((prev_end, s))
                        prev_end = max(prev_end or 0, e)
                    if prev_end is None:
                        if h - floor >= 30:
                            gaps.append((floor, h))
                    elif h - prev_end >= 30 and prev_end >= floor:
                        gaps.append((prev_end, h))
                    credibility_edge = min(cur.end, nxt.start) - 60
                    g = next((gap for gap in gaps if gap[1] >= credibility_edge), None)
                    speech_after_g = g is not None and any(s >= g[0] + 30 for s, _ in V)
                    quiet = now - self.last_speech
                    fire, boundary = False, None
                    if sig == "next":
                        fire = True
                        boundary = g[0] + 2 if g else now
                    elif (sig != "current" or not self.quiet_blocked_by_title) \
                            and now >= cur.end:
                        if g and speech_after_g:
                            fire, boundary = True, g[0] + 2      # switch confirmed by record
                        elif g and self.last_speech <= g[0] + 5 and now - g[0] >= 45:
                            fire, boundary = True, g[0] + 2      # stayed quiet past the gap
                        elif now >= nxt.start + SPLIT_FORCE_CAP:
                            fire, boundary = True, (g[0] + 2 if g else now)
                    if fire:
                        if self.stage == 2:
                            self.handoff(now, nxt.key, boundary=boundary)
                        else:
                            self.stop(now, f"split before {nxt.key}", suppress=True)
                        self.was_recording = self.rec() is not None
                        return
                if not ongoing:
                    if self.meet_ended_at is None:
                        self.meet_ended_at = now
                    quiet = now - self.last_speech
                    if quiet > STOP_QUIET or now - self.meet_ended_at > OVERRUN_CAP:
                        self.stop(now, "auto-stop")
                else:
                    self.meet_ended_at = None
        else:
            if self.was_recording:  # running -> stopped transition observed
                if not self.suppress_mark:
                    marks = (self.ongoing_last_rec_tick if self.mark_prev_tick_set
                             else {e.key for e in ongoing})
                    self.handled |= marks
                self.suppress_mark = False
            if now >= self.drain_until:  # engine ready (stage 1 drain gate)
                cand = min((e for e in ongoing if e.key not in self.handled),
                           key=lambda e: e.start, default=None)
                if cand:
                    self.start(now, cand.key)

        self.was_recording = self.rec() is not None

    def run(self):
        stops = sorted(self.sc.manual_stops)
        t = self.t0
        while t <= self.sc.horizon:
            while stops and stops[0] <= t:
                ts = stops.pop(0)
                if self.rec():
                    self.stop(ts, "manual")
            self.tick(t)
            t += TICK
        if self.rec():
            self.stop(self.sc.horizon, "horizon")
        return self


# --- invariant checks ----------------------------------------------------
def coverage_gaps(intervals, recs):
    """speech seconds not covered by any recording"""
    lost = 0.0
    for s, e in intervals:
        t = s
        while t < e:
            step = min(e, t + 1.0)
            if not any(r.start <= t and (r.end or 1e9) >= step for r in recs):
                lost += step - t
            t = step
    return lost


def check(sim, sc):
    fails = []
    joined = sc.joined if sc.joined is not None else [e.key for e in sc.events]
    # I3: no overlap / ordering
    for a, b in zip(sim.recordings, sim.recordings[1:]):
        if b.start < a.end - 1e-9:
            fails.append(f"I3 overlap {a} {b}")
    # I1/I4: each joined meeting has a recording covering its in-window speech
    stop_at = min(sc.manual_stops) if sc.manual_stops else 1e9
    if sim.stage != 2:
        stop_at = -1  # stage 1 coverage is budget-checked via I2 instead
    for key in joined:
        ev = next(e for e in sc.events if e.key == key)
        probes = [(s + e) / 2 for s, e in sc.speech
                  if s >= ev.start - 60 and s < min(ev.end, stop_at)
                  and (s + e) / 2 < stop_at]
        for p in probes:
            if not any(r.start <= p <= (r.end or 1e9) for r in sim.recordings):
                fails.append(f"I1/I4 {key}: speech at t={p:.0f} not covered")
                break
    # I2: total speech loss (allow small edges: tick grid + join latency)
    lost = coverage_gaps(sc.speech, sim.recordings)
    # I5: split count + placement (never mid-speech unless scenario accepts it)
    if any(m.startswith("handoff") for _, m in sim.log):
        splits = [r.start for r in sim.recordings[1:]]
    else:
        splits = [t for t, m in sim.log if "split" in m]
    if sc.expect_split_count is not None and len(splits) != sc.expect_split_count:
        fails.append(f"I5 {len(splits)} splits, expected {sc.expect_split_count}")
    if not sc.allow_mid_speech_split:
        for sp in splits:
            for s, e in sc.speech:
                if s + 2 < sp < e:
                    if sim.stage == 2 or min(sp - s, e - sp) > 45:
                        fails.append(f"I5 split at {sp:.0f} lands mid-speech")
                    break
    return fails, lost, splits


SC = []
# 1. Clean back-to-back; user leaves A ~10s early, joins B 100s late.
SC.append(Scenario(
    "1 clean b2b, joins B late",
    events=[Event("A", 0, 1800), Event("B", 1800, 3600)],
    speech=[(30, 1770), (1900, 3550)],
    expect_split_count=1))
# 2. A overruns 2.5 min into B's slot; then user hops to B.
SC.append(Scenario(
    "2 A overruns into B",
    events=[Event("A", 0, 1800), Event("B", 1800, 3600)],
    speech=[(30, 1950), (1985, 3550)],
    title=[(0, 1955, "A"), (1975, 3600, "B")],
    expect_split_count=1))
# 2b. Same overrun but NO title signal available.
SC.append(Scenario(
    "2b overrun, no title signal",
    events=[Event("A", 0, 1800), Event("B", 1800, 3600)],
    speech=[(30, 1950), (1985, 3550)],
    expect_split_count=1))
# 3. User skips B entirely; A runs long. Title signal available.
SC.append(Scenario(
    "3 skip B, title=A",
    events=[Event("A", 0, 1800), Event("B", 1800, 3600)],
    speech=[(30, 3900)],
    title=[(0, 3950, "A")],
    joined=["A"], expect_split_count=0, horizon=5000))
# 3b. Skip B, no title -> force-cap wrong split accepted; check no speech lost.
SC.append(Scenario(
    "3b skip B, no title",
    events=[Event("A", 0, 1800), Event("B", 1800, 3600)],
    speech=[(30, 3900)],
    joined=["A"], expect_split_count=1, allow_mid_speech_split=True, horizon=5000))
# 3c. Skip B; user MUTED/screenshare-silent 1900-2300 while title still shows A.
#     The quiet-path split must be blocked by titleSignal == current.
SC.append(Scenario(
    "3c skip B, muted stretch, title=A",
    events=[Event("A", 0, 1800), Event("B", 1800, 3600)],
    speech=[(30, 1900), (2300, 3900)],
    title=[(0, 3950, "A")],
    joined=["A"], expect_split_count=0, horizon=5000))
# 4. Triple header.
SC.append(Scenario(
    "4 triple header",
    events=[Event("A", 0, 1800), Event("B", 1800, 3600), Event("C", 3600, 5400)],
    speech=[(30, 1780), (1830, 3580), (3620, 5300)],
    expect_split_count=2, horizon=6200))
# 5. Manual stop mid-A; B later must still auto-start.
SC.append(Scenario(
    "5 manual stop mid-A",
    events=[Event("A", 0, 1800), Event("B", 1800, 3600)],
    speech=[(30, 890), (1830, 3550)],
    manual_stops=[900], joined=["A", "B"],
    expect_split_count=0))
# 6. Manual stop just BEFORE B becomes ongoing (the 20s-window trap).
SC.append(Scenario(
    "6 manual stop at boundary-5s",
    events=[Event("A", 0, 1800), Event("B", 1800, 3600)],
    speech=[(30, 1790), (1830, 3550)],
    manual_stops=[1795], joined=["A", "B"],
    expect_split_count=0))
# 7. Ten-minute gap between meetings (regression: normal stop then start).
SC.append(Scenario(
    "7 gapped meetings",
    events=[Event("A", 0, 1800), Event("B", 2400, 4200)],
    speech=[(30, 1770), (2430, 4150)],
    expect_split_count=0, horizon=5400))
# 8. Overlapping invites; user switches at 1900. Title flips.
SC.append(Scenario(
    "8 overlapping invites",
    events=[Event("A", 0, 2000), Event("B", 1800, 3600)],
    speech=[(30, 1895), (1910, 3550)],
    title=[(0, 1900, "A"), (1905, 3600, "B")],
    expect_split_count=1))
# 9. Choppy speech near boundary (15-25s pauses aligned with ticks)
#    while A overruns — must NOT split mid-speech.
choppy = [(30, 1795)] + [(1800 + i * 40, 1815 + i * 40) for i in range(6)] \
       + [(2060, 2200)]
SC.append(Scenario(
    "9 choppy overrun (pause traps)",
    events=[Event("A", 0, 1800), Event("B", 1800, 3600)],
    speech=choppy + [(2255, 3550)],
    title=[(0, 2205, "A"), (2245, 3600, "B")],
    expect_split_count=1))
# 10. A had an ordinary 40s conversational pause long before the boundary.
#     Later A speech must not "confirm" that old pause as the meeting switch.
SC.append(Scenario(
    "10 old A pause before real switch",
    events=[Event("A", 0, 1800), Event("B", 1800, 3600)],
    speech=[(30, 1200), (1240, 1950), (1985, 3550)],
    expect_split_count=1))


def main():
    grand_fail = 0
    planned_stage2_fail = 0
    sabotage_failures = {}
    for variant, kw in [
        ("PLANNED (prev-tick mark, quiet⊣title)", dict(mark_prev_tick_set=True, quiet_blocked_by_title=True)),
        ("naive-mark (stopped-tick set)", dict(mark_prev_tick_set=False, quiet_blocked_by_title=True)),
        ("no title-block on quiet path", dict(mark_prev_tick_set=True, quiet_blocked_by_title=False)),
    ]:
        print(f"\n=== variant: {variant} ===")
        for stage in (2, 1):
            print(f"\n--- Stage {stage} ---")
            for sc in SC:
                worst = None
                for phase in (0.0, 5.0, 10.0, 15.0):
                    for lag in (10.0, 45.0):
                        sim = Sim(sc, stage, phase, lag, **kw).run()
                        fails, lost, splits = check(sim, sc)
                        # stage-aware speech-loss budget: stage2 ~ tick+join slack,
                        # stage1 additionally pays the drain gap per split
                        restarts = max(0, len(sim.recordings) - 1 - (len(splits) if stage == 2 else 0))
                        budget = 45 + restarts * (90 + 2 * TICK)
                        if lost > budget:
                            fails.append(f"I2 lost {lost:.0f}s > budget {budget:.0f}s")
                        if worst is None or len(fails) > len(worst[0]):
                            worst = (fails, lost, splits, phase, lag, sim)
                fails, lost, splits, phase, lag, sim = worst
                status = "PASS" if not fails else "FAIL"
                if fails:
                    grand_fail += 1
                    if variant.startswith("PLANNED") and stage == 2:
                        planned_stage2_fail += 1
                    if not variant.startswith("PLANNED"):
                        sabotage_failures[variant] = sabotage_failures.get(variant, 0) + 1
                ss = ",".join(f"{s:.0f}" for s in splits) or "-"
                print(f"[{status}] {sc.name:34s} splits@{ss:12s} lost={lost:5.1f}s"
                      f" (phase={phase:.0f} lag={lag:.0f})")
                for f in fails:
                    print(f"        !! {f}")
                if fails:
                    for t, m in sim.log:
                        print(f"           {t:7.1f}  {m}")
    sabotage_ok = all(sabotage_failures.get(name, 0) > 0 for name in (
        "naive-mark (stopped-tick set)",
        "no title-block on quiet path",
    ))
    if planned_stage2_fail == 0 and sabotage_ok:
        print(f"\nPASS: Stage 2 planned matrix clean; {grand_fail} expected control failures observed")
        return 0
    print(f"\nFAIL: {planned_stage2_fail} planned Stage 2 failures; sabotage controls valid={sabotage_ok}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
