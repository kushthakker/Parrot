# Learnings

## 2026-08-05 — Back-to-back meeting handoff

- A hot handoff must keep ScreenCaptureKit, AVAudioEngine, and the Whisper loop alive; only rotate queue-confined audio writer URLs and meeting/span bookkeeping.
- `consumedSamples` advances before async transcription finishes. Completeness gates need a separate capture-relative watermark advanced after decode, filtering, and synchronous segment persistence.
- Use one capture epoch across an A→B→C session. Persist transcript times meeting-locally, but route and refine them using capture-relative span boundaries.
- Reserve post-call work in FIFO order at handoff time, before waiting for decode. Reset and snapshot the shared provider meter inside that serialized chain for live calls, imports, and crash recovery.
- A 30-second pause anywhere in the previous ten minutes is not enough evidence of a switch. Require the decoded gap to reach near the scheduled boundary, while title signals remain the fast path and `showsCurrent` blocks forced splits.
- Gap search must include leading decoded silence; otherwise a silent A followed by speaking B has no detectable switch gap.
- Provisional refinement in A→B→C must ignore gaps before B's span start, or a rapid third handoff can reuse the A→B gap.
- Rotated audio paths must be unique beyond second resolution; reusing the active URL can reopen `AVAudioFile(forWriting:)` and truncate the finished recording.
