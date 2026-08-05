# Back-to-Back Meetings: Split & Hot Handoff Plan

Goal: with consecutive Google Meet invites (A 10:00–10:30, B 10:30–11:00), Parrot
must end A's recording at the real boundary, start B's with **zero capture gap**,
and run A's post-processing (cleanup → summary → usage) in the background while B
records — each meeting getting its own title, counterpart name, transcript,
report, and cost row.

Non-goals: splitting **manual** recordings automatically (the user pressed record
deliberately; only auto-started recordings are auto-managed — same rule as
auto-stop today), non-Meet platforms, and any change to the transcription
pipeline itself.

---

## 1. Why it fails today (exact culprits)

| # | Bug | Where |
|---|-----|-------|
| 1 | Auto-stop fires only when **no** Meet event is ongoing. B becomes ongoing the instant A ends, so A's recording sails through B as one merged blob. | `MeetingAutoRecorder.swift:119` |
| 2 | While recording, **every** ongoing Meet event is marked handled — so B is poisoned during A's recording and never auto-starts, even after A stops. (The line exists to stop manual-Stop → instant restart.) | `MeetingAutoRecorder.swift:106` |
| 3 | `stopRecording` holds `isStopping` through the WhisperKit **drain** of the buffered backlog (up to ~30–60 s of audio/stream, several padded-30 s decodes on the throttled M2 Air ⇒ the "Finalizing…" minutes). UI + auto-recorder both refuse a new start during it. The AI chain does *not* block — it's already a detached background Task. | `RecordingManager.swift:246–264`, `MeetingAutoRecorder.swift:139` |
| 4 | A merged A+B recording also gets **one** counterpart name (`CalendarLookup.bestMatch` picks largest overlap), so cleanup + summary address the wrong person for half the call. | consequence of 1+2 |

---

## 2. Design in one picture

```
tick (20s) ──► split decision ──► RecordingManager.handoffRecording()
  calendar: B ongoing & unhandled        │ (capture + Whisper loop NEVER stop)
  + A's scheduled end passed             ├─ rotate .caf writers  → B's files
  + short quiet (~20s)  ──OR──           ├─ close A's span, open B's span
  window title now shows B  ──OR──       ├─ segments route by timestamp:
  force-cap (B.start + 5min)             │    < boundary → A (late drain tail)
                                         │    ≥ boundary → B (re-anchored times)
                                         └─ A-finalize task (background):
                                              wait until decode clock ≥ boundary
                                              → name → clean → summary → usage
                                              (serialized, one chain at a time)
```

Three stages, each independently shippable and testable. Stage 1 alone already
fixes "records through both meetings".

---

## 3. Stage 1 — Split policy (calendar-only, small diff)

**File: `Parrot/Services/MeetingAutoRecorder.swift` only.**

### 3.1 Stop poisoning B

Delete the while-recording blanket marking (line 106). Replace the manual-stop
protection with a **transition rule**: keep `wasRecordingLastTick`; on the tick
where recording transitioned running → stopped (any kind, manual or auto), mark
the events ongoing *at that tick* handled. Same protection, no poison. (Handoffs
happen inside one tick, so no stopped-state tick is observed and nothing gets
spuriously marked — the handoff marks B handled itself.)

**⚠ Self-poisoning guard (review finding):** Stage 1's split is itself a
stop — without care, the transition rule fires on the very next tick and marks
B handled, recreating the bug. A **scheduler-initiated** split-stop must
suppress the transition-marking: set `suppressNextTransitionMark = true` before
`await manager.stopRecording()` and consume the flag when the stopped tick is
observed. (Auto-stop keeps marking — ongoing is empty then anyway; manual stops
keep marking — that's the protection's whole point.)

### 3.2 Track what the recording covers

`autoOccurrenceKey: String?` becomes
`autoEvent: (key: String, end: Date, title: String?)?` — `title` is needed
later as the `currentTitle` input to the Stage 3 matcher. Refresh `end` each
tick from the matching ongoing event (an invite extended mid-call must push the
boundary out); when the event is no longer ongoing, keep the stored values.

### 3.3 The split decision (pure, harness-tested, **simulation-validated**)

**Revised after executable simulation** (`docs/b2b-simulation.py`, §8.0): the
first draft keyed on a live "quiet for ≥30 s" clock — and the simulation proved
that systematically fails the *most common* b2b pattern. When you leave A and
join B within ~20–50 s (your "instantly jump on the next call"), B's own audio
resets the quiet clock before any 20 s tick can observe 30 s of silence; only
the 5-minute force-cap ever fired, putting B's first 2–5 minutes into A. The
validated rule reads the **segment record** instead — the transcript the engine
is already producing, which is *exact* once decode passes a window — and makes
the decision a pure function:

```swift
// record: merged speech intervals from the meeting's segments (capture-relative),
// trustworthy up to `horizon` = engine.consumedThrough().
struct SplitInputs {
    var now, horizon: TimeInterval          // capture-relative
    var recordingStart, currentEnd, nextStart: TimeInterval
    var speech: [ClosedRange<TimeInterval>] // decoded record, merged
    var lastSpeechAt: TimeInterval          // live estimate (levels + segments)
    var titleSignal: TitleSignal
}
// Find the first silence gap in the record: length ≥ 30s, starting after
// max(recordingStart, nextStart − 600). Trailing silence (last speech → horizon)
// counts. Returns the gap, or nil.
static func splitGap(_ i: SplitInputs) -> ClosedRange<TimeInterval>?

static func splitDecision(_ i: SplitInputs) -> (fire: Bool, boundary: TimeInterval?) {
    let g = splitGap(i)
    if i.titleSignal == .showsNext {                       // user demonstrably moved on
        return (true, g.map { $0.lowerBound + 2 } ?? i.now)  // provisional 'now' if record lags
    }
    guard i.titleSignal != .showsCurrent, i.now >= i.currentEnd else { return (false, nil) }
    if let g {
        if i.speech.contains(where: { $0.lowerBound >= g.lowerBound + 30 }) {
            return (true, g.lowerBound + 2)                // switch CONFIRMED: speech after the gap
        }
        if i.lastSpeechAt <= g.lowerBound + 5, i.now - g.lowerBound >= 45 {
            return (true, g.lowerBound + 2)                // stayed quiet past the gap
        }
    }
    if i.now >= i.nextStart + 300 {                        // force-cap: 5 min into B
        return (true, g.map { $0.lowerBound + 2 } ?? i.now)
    }
    return (false, nil)
}
```

Key properties, each earned in simulation:
- **The cut lands where the silence is, not when detection happens.** Spans
  route segments by timestamp (§4.3), so firing 40–70 s late costs *nothing* in
  Stage 2 — the boundary is backdated into the real inter-call gap.
- **Gap ≥ 30 s** distinguishes a call switch from conversational pauses (the
  choppy-speech scenario with 25 s pauses at tick instants never misfires).
  Switches faster than ~30 s of dead air are title-signal/force-cap territory.
- **`showsCurrent` blocks the audio paths and the force-cap** — the
  muted-screenshare-while-skipping-B scenario splits wrongly without this.
- Stage 1 (interim) uses the same `fire` decision but must cut at detection
  time (a real stop can't backdate). Simulated worst case at 45 s decode lag:
  the cut lands up to ~1 min into B, which stays in A's transcript — not lost.

### 3.4 New while-recording branch (auto recordings only)

1. Update `lastSpeechAt` (existing logic, unchanged).
2. `next` = earliest ongoing Meet event whose occurrence key is unhandled and ≠ `autoEvent.key`.
3. If `next` exists and `splitDecision(...)` fires → **switch**. Stage 1: set
   `suppressNextTransitionMark`, `await manager.stopRecording()`, clear
   `autoEvent`, do **not** mark `next` handled — the existing auto-start path
   picks B up on a later tick, as soon as `isStopping` clears and the engine is
   ready (gap ≈ drain time; Stage 2 removes it). Stage 2: call
   `handoffRecording` instead (§4); **only on success** set `autoEvent` to
   next, mark next handled, `lastSpeechAt = now`. On failure keep recording A
   (the safe default) and leave next unhandled so the next tick retries; after
   3 failed attempts mark next handled to stop a 20 s retry storm (mirrors how
   auto-start already prefers giving up over prompting/spamming).
4. Auto-stop rule unchanged (no ongoing Meet at all + 240 s quiet / 45 min cap).

Manual recordings (`autoEvent == nil`): never split, never auto-stop — exactly
today's contract.

---

## 4. Stage 2 — Hot handoff (the gap killer)

Insight: at a boundary **nothing needs tearing down**. `stopRecording`'s cost is
teardown + drain, which exist so the app can go idle. A handoff keeps
ScreenCaptureKit, AVAudioEngine, and the Whisper loop running continuously; the
boundary is bookkeeping.

### 4.1 `AudioCaptureManager.rotateFiles()` — new

```swift
@MainActor func rotateFiles() -> (system: URL?, mic: URL?)
```

- New timestamped URLs (same naming scheme as `startCapture`).
- Per stream: `writeQueue.sync { audioFile = nil; queueURL = newURL }` — the
  serial `sync` is a barrier: every already-enqueued write lands first (into the
  old file), then the old `AVAudioFile` deallocates ⇒ `.caf` header finalized,
  and the queue-confined URL flips in the same block.
- Then update the main-actor `systemAudioURL` / `micAudioURL` (UI/meeting
  bookkeeping only); return the new pair.

**Truncation hazard (must-fix, design revised in review):** today `appendAudio`
captures the URL at enqueue time and the write block lazily recreates
`AVAudioFile(forWriting:)` — which **truncates**. That capture is safe today
only because the URL never changes mid-session; rotation makes it a live race
(a write enqueued around the rotation could recreate — and destroy — A's
finished file; same hazard class `filesClosed` guards in
`AudioCaptureManager.swift:21`). A generation-token check is NOT sufficient:
URL and token are read in two non-atomic steps from the capture thread, so
(old URL, new token) can still pair up. The airtight fix is **queue-confined
URL ownership**: the write block never uses an enqueue-time URL at all — it
reads `queueURL`, a property owned by its own serial queue, mutated only
inside `queue.sync` blocks (rotation above; `startCapture` seeds it the same
way before any write exists). Serial FIFO then guarantees: writes enqueued
before the rotation block run before it (old file object still set → append to
A); writes after it see file == nil and `queueURL` == new → lazily create B's
file. No token, no extra lock on the hot path, no reachable truncation state.
`filesClosed` behavior at final stop is unchanged.

Mic-less recordings: mic side is a no-op, returns `nil` (B is single-track like A).

### 4.2 `TranscriptionEngine` — two tiny additions, loop untouched

- `func consumedThrough() -> TimeInterval` — under `bufferLock`, `min` over
  **active** sources of `consumedSamples[source] / 16_000 +
  (localClockOffset[source] ?? 0)`. The offset term is load-bearing (review
  finding): it is exactly how segment timestamps are computed
  (`TranscriptionEngine.swift:410`), and after a mid-call mic device change
  `reanchorLocalClock` shifts the mic clock forward to skip the dead gap —
  without it, the mic's raw sample count sits permanently behind wall-clock and
  every finalize gate would wait out its full 180 s cap. Skip `.me` when the
  mic never delivered (its counter would sit at 0 forever and stall the wait —
  pass the active-source set in, or derive from a `sawAudio` flag per source).
- `var isStopped: Bool` — `transcriptionTask == nil`. A finished drain implies
  everything was consumed; used as the wait's escape hatch (§4.4).

No changes to `startTranscribing` / `stopTranscribing` / the decode loop.
`meetingStartTime` and the sample clocks stay anchored to **capture start** for
the whole multi-meeting session; per-meeting re-anchoring happens at persist
time (§4.3), not in the engine.

### 4.3 `RecordingManager` — spans, routing, handoff

**Spans** (replaces the single `currentMeeting` assumption; handles A→B→C
chains):

```swift
private struct MeetingSpan { let meeting: Meeting; let startElapsed: TimeInterval; var endElapsed: TimeInterval? }
private var spans: [MeetingSpan] = []   // ordered; last = live meeting
```

`startRecording` seeds `spans = [(meeting, 0, nil)]`. `currentMeeting` stays (UI
observes it) = last span's meeting.

**`addSegment` routing** (top of the function, before everything else): find the
span containing `result.startTime` (engine times are capture-relative); convert
to meeting-local by subtracting `span.startElapsed`; run the existing
echo-dedup + insert against *that* span's meeting with local times. A drain-tail
segment arriving after the handoff still lands in A — correctly, automatically.
Extract the lookup as a pure helper for the harness:
`static func spanIndex(for time: TimeInterval, boundaries: [TimeInterval]) -> Int`.
Accepted limitation: the ±2.5 s echo-dedup window can't see across the
boundary, so one echoed line straddling the cut could survive as a duplicate
(one copy at A's tail, one at B's head) — cosmetic, rare, and the cleanup pass
tends to leave both readable; not worth cross-meeting dedup complexity.

**`handoffRecording`** — new:

```swift
func handoffRecording(modelContext: ModelContext, title: String?,
                      boundaryElapsed: TimeInterval) async throws -> Meeting?
```

The boundary comes from `splitDecision` (§3.3) — usually *earlier* than the
call moment, backdated into the recorded silence between the calls.

**Boundary refinement (simulation finding):** the title path can fire before
the record has caught up to the switch (heavy decode lag) — its `now` boundary
is provisional. After the handoff, when `consumedThrough() ≥ provisional + 30`,
search the record for the true silence gap overlapping
`[provisional − 60, provisional + 30]`; if found, move the span boundary to
`gap.start + 2` and reassign the few segments that landed in between (update
`segment.meeting` + re-base their times — SwiftData makes this a trivial loop).
If the record shows continuous speech there, keep the provisional cut. The
confirmed-gap and quiet paths already cut exactly and refine to themselves.

Honest cosmetic note: the `.caf` **files** rotate at fire time while the
**transcript** boundary may be backdated — so a few seconds of B's audio can
physically sit at the tail of A's file. Playback-only; the transcript (what
cleanup, summary, and the user read) is always cut correctly.

1. `guard isRecording, !isStopping, !isHandingOff` (+ new `isHandingOff` flag; `stopRecording` also guards `!isHandingOff`).
2. `boundaryElapsed = Date.now − captureEpoch`. `captureEpoch` must be **the
   same `Date` value passed to `startTranscribing(meetingStartTime:)`** —
   today `startRecording` calls `.now` twice a few ms apart
   (`RecordingManager.swift:228,232`); store one value and pass it to both, so
   the boundary and the engine's segment clock share an epoch exactly.
3. Close A: `spans[last].endElapsed = boundaryElapsed`; `meeting.duration = boundaryElapsed − span.startElapsed`; `status = .processing`; save.
4. Create B via `makeMeeting()` (extract the meeting-creation block from `startRecording:183–191` — profile, brief, snapshot — so both paths share it).
5. `let urls = audioCaptureManager.rotateFiles()`; assign B's `systemAudioPath` / `micAudioPath`; set B's title from the event invite.
6. Append B's span; `currentMeeting = B`; `recordingStartTime = .now`; `elapsedTime = 0`; save. (LiveRecordingView follows `currentMeeting` observably — the timer and transcript reset to B on their own.)
7. Spawn A's **finalize task** (§4.4). Total await-free work ≈ milliseconds; no drain, no capture restart.

**`stopRecording`** refactor: extract the post-chain block
(`RecordingManager.swift:279–292`) into
`finalizeMeeting(_ meeting: Meeting) async` and call it from both paths. Stop
keeps its full teardown (capture stop + drain) and then finalizes the *last*
span; earlier spans already have their own finalize tasks in flight.

### 4.4 A-completeness gate — cleanup must never see a partial transcript

The post-call contract is "clean the **complete** transcript at the end." At
handoff time A's final words are still in the decode backlog. Before A's chain
runs:

```swift
while engine.consumedThrough() < boundaryElapsed && !engine.isStopped && elapsed < 180 {
    try? await Task.sleep(for: .seconds(2))
}
await Task.yield()   // let the last enqueued addSegment hops land
```

- `consumedThrough ≥ boundary` ⇒ every A-chunk decoded ⇒ every A-segment emitted.
- `isStopped` ⇒ user stopped B and the drain finished ⇒ trivially complete.
- 180 s cap ⇒ a wedged decode can't block A's report forever (matches the
  existing "drain is uncapped" ponytail note in `TranscriptionEngine.swift:689`).
- Deepgram/streaming backend: no local backlog — skip the wait, 5 s grace.

### 4.5 Usage metering — the silent data corruptor (must-fix)

Today: `startRecording` calls `provider.resetUsage()` and `writeAIUsage` reads
the global meter at chain end. With a handoff, B's start would zero the meter
before A's summary runs, and B's stop would read A's summary tokens into B's
cost row. Fix (no provider-protocol change):

1. **Serialize post-chains** — one meeting's chain at a time, FIFO (a simple
   actor/async-semaphore `postChainGate` in `RecordingManager`). Also kind to
   API rate limits on one key.
2. Inside the gate: `resetUsage()` at chain start, run name → clean → postProcess
   → summary, then `writeAIUsage` reads the meter — all attributable to exactly
   one meeting, because live copilot is removed and the provider is *only*
   called from post-chains now.
3. Delete `resetUsage()` from `startRecording` (`RecordingManager.swift:229`) —
   it belongs to the chain.
4. **The gate must wrap every provider-calling chain, not just live stops
   (review finding):** there are four — the stop chain
   (`RecordingManager.swift:279–292`), the handoff finalize chain (new), the
   **import** chain (`RecordingManager.swift:389–390`), and the launch-time
   **crash-recovery** chain (`finishRecovery`,
   `RecordingManager.swift:143–144`). Recovery today spawns one concurrent
   Task per interrupted meeting — two recovered meetings already garble each
   other's meters in the current build; routing all four through the gate fixes
   that pre-existing bug as a side effect. Import/recovery keep their existing
   `backendOverride`/no-cleaning shapes; only the reset-and-read moves inside
   the gate.

Cleaning tokens already travel by value (`TranscriptCleaner` returns its own
totals) — unaffected.

---

## 5. Stage 3 — "The link changed" window-title signal

Zero new permissions: we already hold Screen Recording (mandatory for system
audio; auto-start preflights `CGPreflightScreenCaptureAccess()`), and
`SCShareableContent` exposes every on-screen window's title. An active Meet tab
titles its window "Meet – {event name}…". This is the precision layer the
Accessibility API would buy — without the Accessibility grant, the per-browser
AX-tree fragility, or the Automation consent prompt of AppleScript. (AX stays a
future option if titles ever prove insufficient.)

**In `MeetingAutoRecorder`:**

- Fetch titles at most once per tick, and **only when a split decision is
  pending** (recording + `next` exists):
  `SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)`
  → `windows.compactMap(\.title)`.
- Pure matcher (harness-tested):

```swift
enum TitleSignal { case showsCurrent, showsNext, unknown }
static func titleSignal(windowTitles: [String], currentTitle: String?, nextTitle: String?) -> TitleSignal
```

Rules: consider only titles that look like a Meet surface (case-insensitive
contains "meet"); a candidate matches when the window title contains the event
title (trimmed, ≥ 4 chars — refuse trivial/empty matches); `showsNext` wins over
`showsCurrent` if both somehow match; anything else → `.unknown`. `.unknown`
must degrade to exactly Stage 1 behavior — the calendar+quiet rule carries the
decision. (Known blind spot, by design: a backgrounded Meet tab has no window
title; that's why this layer refines and never replaces the calendar layer.)

Wire the result into `SplitInputs.titleSignal`. This is what resolves the two
ambiguous cases: A overrunning into B's slot (title still shows A → hold) and
the user skipping B while A runs long (never force-split while `showsCurrent`).

---

## 6. Stage 4 (optional polish, after 1–3 verified)

- **Manual "Stop & Start Next"** menu-bar item → `handoffRecording(title: nil)`.
  Gives the "jump on the next call NOW" escape hatch for manual recordings and
  makes the handoff testable without a calendar (see §8).
- **Empty-recording discard**: at finalize, an **auto-started** meeting with
  zero segments (user never joined B; force-cap recorded silence) is deleted
  instead of processed. Auto-started only — never discard anything the user
  started by hand.

---

## 7. Edge cases — decided up front

| Case | Behavior |
|------|----------|
| A overruns 3 min into B's slot, user still talking | No split while speech flows and title shows A; split on first ~20 s quiet, or at B.start+5 min force-cap if title signal is `.unknown`. |
| User skips B, stays on A for the whole hour | With Stage 3: `showsCurrent` blocks the force-cap → no split (correct). Without title signal: force-cap splits wrongly at B.start+5 min — accepted cost: both halves still recorded/cleaned; B's junk recording is discarded empty or contains A-tail. |
| User joins B two minutes late | Recording B starts at the boundary anyway; B's transcript opens with silence, nothing missed. |
| User leaves A five minutes early | B isn't "ongoing" yet, quiet < 240 s → recording A idles until B's scheduled start, then splits (quiet ≥ 20 s is long since true). A's tail has a few silent minutes — harmless. |
| Triple-header A→B→C | Spans generalize; each handoff closes one span. A's chain may still be running when B's boundary hits — the serial post-chain gate queues them FIFO. |
| User presses Stop right after a handoff | `stopRecording` drains fully; A's finalize wait exits via `isStopped`; both chains run in order through the gate. |
| Mid-call mic device change then handoff | Engine clocks already re-anchor (`reanchorLocalClock`); spans compare against the same capture-relative timeline addSegment already receives — no interaction. |
| Recurring events | Occurrence keys (`id@epoch`) already disambiguate; unchanged. |
| Meeting invite extended mid-call | `autoEvent.end` refreshed each tick → boundary pushes out. |
| Later, unrelated recording starts | Fresh `startTranscribing` resets engine counters — safe, because any prior finalize-wait already exited via `isStopped` (a new start requires the old drain to have finished). |
| User deletes meeting A while its finalize chain is waiting/running | Pre-existing race (today's stop-chain has it too), slightly widened by the gate wait. Chain checks `meeting.isDeleted` after the gate and before each save; a deleted meeting's chain exits silently. |
| App quits/crashes mid-session with A `.processing` and B `.recording` | Launch-time `recoverInterruptedRecordings` already handles both statuses per meeting independently: A re-runs its chain (segments exist), B is salvaged or failed-if-empty. Spans are in-memory only — nothing to persist. |

---

## 8. Test plan

### 8.0 Executable simulation (already run — this is how §3.3 got its shape)

`docs/b2b-simulation.py` models the full tick state machine against 12
scenarios × 4 tick phases × 2 decode lags (10 s / 45 s thermal throttle), for
Stage 1 and Stage 2, checking five invariants (per-meeting coverage, zero
speech loss, no overlap/double-start, no poisoning, cut-lands-in-silence).
Result: **Stage 2 planned design passes all 96 runs**; Stage 1 passes except
the two documented cut-at-detection cases at 45 s lag. Two sabotage variants
prove the rules are load-bearing: stopped-tick marking fails "manual stop 5 s
before the boundary" (B poisoned forever), and removing the `showsCurrent`
block fails "skip B" and "muted screenshare" (wrong split). The scenarios
include: clean b2b with a late join, overrun with/without title, skipped B
(with/without title, with a muted stretch), triple header, manual stops (mid-A
and at boundary−5 s), a 10-min gap, overlapping invites, and choppy speech with
pauses aligned to tick instants. Re-run it after any rule change — it's the
spec.

**Harness (`make test`, ProfileTest.swift) — pure functions, no audio needed:**
- `splitGap` / `splitDecision` ports of the simulation matrix: confirmed-switch
  gap ✓, fast-switch 35 s gap ✓ (the case the quiet-clock draft failed),
  choppy 25 s pauses ✗, quiet-persists path ✓, force-cap ✓,
  force-cap+`showsCurrent` ✗, `showsNext` with lagging record → provisional
  `now` ✓, pre-`currentEnd` audio paths ✗.
- Boundary refinement: provisional cut + record catching up → moved into the
  true gap, segments in between reassigned; continuous speech → provisional kept.
- `titleSignal`: exact/partial/case-insensitive matches, short-title refusal,
  both-match precedence, no Meet window → `.unknown`.
- Span routing: segment at boundary−ε → A, boundary+ε → B (local time re-based),
  three-span chain, tail segment after span closed.
- Transition rule: running→stopped marks ongoing handled; handoff tick does
  not; a **split-stop with `suppressNextTransitionMark` set does not** (the
  Stage 1 self-poisoning regression test — this exact case is why the flag
  exists).

**Live validation (needs the Google account synced into macOS Calendar —
System Settings → Internet Accounts; still the outstanding setup step):**
1. Two 3-minute back-to-back Meet invites; join both, speak through the
   boundary. Expect: two meetings, each with invite title + counterpart name;
   split within ~20–40 s of the boundary; B's first words present (the zero-gap
   check); A's last words present (the drain-tail routing check); Me/Them intact
   in both; two complete post-chains; separate cost rows, no double-counted
   summary tokens.
2. Overrun: keep talking 2 min past A's end → verify hold-then-split.
3. Stop B seconds after the split → verify both chains complete via the gate.
4. No calendar needed: manual recording + "Stop & Start Next" (Stage 4)
   exercises rotation/spans/finalize-wait solo with music as "Them".

**Regression:** single-meeting auto record/stop, manual record/stop, file
import, mic-less recording, cleanup/summary/usage on a normal call.

---

## 9. Risks & mitigations (ranked)

1. **File truncation at rotation** — queue-confined URL ownership (§4.1; a
   generation token was considered and rejected as still racy). The one bug
   that destroys data; the mitigation is structural, not probabilistic.
2. **Cleanup on incomplete transcript** — consumedThrough gate (offset-aware,
   §4.2) + `isStopped` escape + cap (§4.4).
3. **Meter cross-attribution** — serial gate around all four provider chains +
   reset-in-chain + delete the startRecording reset (§4.5).
4. **Tick reentrancy** — all new decision work stays inside the existing
   `tickInFlight` guard; `handoffRecording` has its own `isHandingOff` flag and
   mutual guards with `stopRecording`. (Every `await` on @MainActor is an
   interleave point — this codebase has been bitten before.)
5. **Wrong split on a merged/odd calendar** — worst case is today's merged-blob
   behavior or one extra split; never data loss.

## 10. Order of work

1. Stage 1 + its harness tests → build, install, live-validate scenario 1
   (accepting the drain-sized gap). *Smallest diff that ends the merged-blob bug.*
2. Stage 2 (§4.1 → §4.2 → §4.3 → §4.4 → §4.5, in that order — each compiles
   standalone) + span/routing tests → live-validate scenarios 1–3.
3. Stage 3 + matcher tests → re-run scenario 1 with the overrun variant.
4. Stage 4 polish. Update FILEMAP.md if any new file is added (current plan: none
   — everything lands in existing files). Version bump + `make install` per stage.
