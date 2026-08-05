import AVFoundation
import WhisperKit
import Combine
import os

/// Which capture stream a piece of audio came from.
enum AudioSource: CaseIterable {
    /// Microphone — the user.
    case me
    /// System audio — everyone else on the call.
    case them

    var label: String {
        switch self {
        case .me: "Me"
        case .them: "Them"
        }
    }
}

/// Wraps WhisperKit for real-time streaming transcription. The microphone ("Me")
/// and system audio ("Them") streams are buffered and transcribed separately, so
/// every segment knows who was talking — no diarization model needed.
@Observable
final class TranscriptionEngine {
    private var whisperKit: WhisperKit?
    private var audioBuffers: [AudioSource: [Float]] = [.me: [], .them: []]
    private let bufferLock = OSAllocatedUnfairLock()
    private var transcriptionTask: Task<Void, Never>?
    /// Live Deepgram sockets, one per source, when the deepgram backend is
    /// active. Audio routes straight to them instead of the chunk buffers.
    /// Same benign cross-thread pattern as `isCapturing`.
    private var deepgramStreamers: [AudioSource: DeepgramStreamer] = [:]
    /// Sources whose Deepgram socket has failed: their audio falls back to the
    /// local buffer/loop path for the rest of the session. Per-source, so one
    /// dead socket (a mic that stopped feeding it) doesn't take the other,
    /// healthy stream off Deepgram with it. Guarded by `bufferLock`.
    private var deepgramFailedSources: Set<AudioSource> = []
    /// Offset added to locally-derived timestamps, per source. Sample counts
    /// don't measure dead time: when a stream falls off Deepgram mid-call (or
    /// the mic restarts after a device change) the counter is way behind the
    /// meeting clock, and without re-anchoring the fallback segments restart
    /// at 0:00 — the bug that filed the back half of a call under minute 3.
    /// Guarded by `bufferLock`.
    private var localClockOffset: [AudioSource: TimeInterval] = [:]
    /// Total samples consumed (and freed) per stream by the local loop. The
    /// buffers only ever hold not-yet-transcribed samples, so memory stays flat
    /// over a long call; these running totals keep segment timestamps absolute.
    /// Guarded by `bufferLock` (the loop and `reanchorLocalClock` both touch it).
    private var consumedSamples: [AudioSource: Int] = [:]
    /// Capture-relative watermark advanced only after a dequeued chunk has
    /// finished decoding (and its segment callback has run), or after proven
    /// silence has been discarded. Guarded by `bufferLock`.
    private var completedThrough: [AudioSource: TimeInterval] = [:]
    /// Capture-relative end of audio actually received per source. A source
    /// that disappears before a handoff only needs decoding through its own
    /// last buffer, not through a later wall-clock boundary. Guarded by lock.
    private var receivedThrough: [AudioSource: TimeInterval] = [:]
    /// Sources that have delivered at least one buffer this session. Lets
    /// `consumedThrough(activeSources:)` skip a mic that never came up (its counter would sit
    /// at 0 forever and stall every completeness wait). Guarded by `bufferLock`.
    private var sawAudioSources: Set<AudioSource> = []
    private var meetingStartTime = Date()

    /// PARROT_LOOP_TRACE=1: print every raw decode piece before filtering —
    /// the tell for "the loop decoded it but a filter ate it" class of drops.
    static let loopTrace = ProcessInfo.processInfo.environment["PARROT_LOOP_TRACE"] != nil

    private(set) var isReady = false
    private(set) var isTranscribing = false
    private(set) var currentText = ""
    /// True while live audio carries speech-level energy. Drives the typing
    /// bubble on chunked backends (Groq, local Whisper) that have no interim
    /// stream — the bubble shows dots while someone talks, text when interims
    /// exist. Same benign cross-thread pattern as the streamers dict.
    private(set) var isHearingSpeech = false
    private var lastSpeechAt = Date.distantPast
    private(set) var modelState: ModelState = .notLoaded
    /// One-line notice when a cloud backend can't be used (missing key, API
    /// errors) and the session is running on-device instead. Shown in the
    /// live device bar.
    private(set) var cloudNotice: String?

    /// True once the live transcription task has fully drained and released.
    /// RecordingManager uses this as the completeness wait's escape hatch when
    /// the user stops the final meeting during an earlier meeting's handoff.
    @MainActor
    var isStopped: Bool { transcriptionTask == nil }

    /// Deepgram emits finalized segments directly and has no local decode
    /// backlog while its sockets are healthy. Handoff finalization uses a short
    /// grace instead of waiting on the local sample clock in that case.
    @MainActor
    var isStreaming: Bool {
        !deepgramStreamers.isEmpty && bufferLock.withLock {
            !sawAudioSources.isEmpty && deepgramFailedSources.isDisjoint(with: sawAudioSources)
        }
    }

    /// True when at least one source that has delivered audio still routes to
    /// Deepgram. A mixed session (one healthy stream + one local fallback)
    /// needs both the local completion targets and the streaming-final grace.
    @MainActor
    var hasHealthyStreamingSource: Bool {
        bufferLock.withLock {
            Self.needsStreamingGrace(
                sawAudioSources: sawAudioSources,
                failedSources: deepgramFailedSources,
                hasStreamers: !deepgramStreamers.isEmpty)
        }
    }

    nonisolated static func needsStreamingGrace(
        sawAudioSources: Set<AudioSource>,
        failedSources: Set<AudioSource>,
        hasStreamers: Bool
    ) -> Bool {
        hasStreamers && sawAudioSources.contains { !failedSources.contains($0) }
    }

    /// Called when a finalized transcript segment is ready
    var onSegment: (@MainActor (TranscriptionResult) -> Void)?

    enum ModelState {
        case notLoaded
        case downloading(progress: Double)
        case loading
        case ready
        case error(String)
    }

    struct TranscriptionResult {
        let text: String
        let source: AudioSource
        let startTime: TimeInterval
        let endTime: TimeInterval
        let confidence: Float?
    }

    // MARK: - Model Management

    /// Load WhisperKit with the specified model.
    ///
    /// Two guards against the eternal "Loading WhisperKit model…" state this
    /// used to produce (idle CPU, dead record button, no error):
    /// - If the model is already on disk, pass its folder directly — WhisperKit's
    ///   name resolution goes through the HuggingFace hub even for local models
    ///   and has been observed suspending forever on a live network. A direct
    ///   folder load is also offline-proof.
    /// - The whole init races a deadline; a first-time download can legitimately
    ///   take minutes, but past the deadline the user gets a real error state
    ///   (the dashboard renders it) instead of a spinner that never ends.
    /// @MainActor: `modelState`/`isReady` are UI-observed, and a nonisolated
    /// async func runs on the global executor, not the caller's actor — mutating
    /// them there fires SwiftUI observation off-main and trips SwiftData's
    /// main-queue assert when a @Query view is invalidating concurrently (the
    /// #18 launch crash-loop). The heavy WhisperKit init is awaited, so main is
    /// never blocked. Same rule for start/stopTranscribing below.
    @MainActor
    func loadModel(_ modelName: String = "base") async {
        modelState = .loading
        do {
            let config = WhisperKitConfig(
                model: modelName,
                modelFolder: Self.localModelFolder(for: modelName)?.path,
                verbose: false,
                logLevel: .none,
                prewarm: true,
                load: true
            )
            whisperKit = try await Self.withTimeout(seconds: 300) { try await WhisperKit(config) }
            modelState = .ready
            isReady = true
        } catch {
            modelState = .error(error.localizedDescription)
            isReady = false
        }
    }

    /// The on-disk folder for a model, if already downloaded. WhisperKit's repo
    /// spells variants inconsistently ("large-v3-turbo" lives in
    /// "openai_whisper-large-v3_turbo"), hence the normalized matcher below.
    nonisolated static func localModelFolder(for modelName: String) -> URL? {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return matchModelFolder(modelName, in: names)
            .map { base.appendingPathComponent($0, isDirectory: true) }
    }

    /// Pure matcher (so --profile-test can drive it): compares case-insensitively
    /// with '_' and '-' unified. Exactly one hit counts — none or ambiguity falls
    /// back to WhisperKit's own hub resolution.
    nonisolated static func matchModelFolder(_ modelName: String, in folderNames: [String]) -> String? {
        func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "_", with: "-") }
        let want = "openai-whisper-" + norm(modelName)
        let hits = folderNames.filter { norm($0) == want }
        return hits.count == 1 ? hits.first : nil
    }

    private struct ModelLoadTimeout: LocalizedError {
        var errorDescription: String? {
            "Model load timed out — check your connection, or pick the model again in Settings"
        }
    }

    nonisolated private static func withTimeout<T: Sendable>(
        seconds: TimeInterval, _ op: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ModelLoadTimeout()
            }
            guard let first = try await group.next() else { throw ModelLoadTimeout() }
            group.cancelAll()
            return first
        }
    }

    // MARK: - Audio Input

    /// Feed audio buffer from AudioCaptureManager, tagged with its stream
    func appendAudio(_ buffer: AVAudioPCMBuffer, source: AudioSource) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))

        // Speech-presence for the typing bubble: mark speech on energetic
        // buffers (same 0.002 floor as the chunk loop), release after 1 s of
        // silence — capture keeps feeding silent buffers, so the flip-off is
        // driven from here too.
        if isTranscribing, frameCount > 0 {
            let energy = samples.reduce(into: Float(0)) { $0 += abs($1) } / Float(frameCount)
            if energy > 0.002 { lastSpeechAt = Date() }
            let hearing = Date().timeIntervalSince(lastSpeechAt) < 1.0
            if hearing != isHearingSpeech {
                Task { @MainActor in self.isHearingSpeech = hearing }
            }
        }

        // Streaming backend: straight to the socket, no chunk buffering.
        let streamer: DeepgramStreamer? = bufferLock.withLock {
            sawAudioSources.insert(source)
            return deepgramFailedSources.contains(source) ? nil : deepgramStreamers[source]
        }
        if let streamer {
            streamer.send(samples)
            return
        }

        bufferLock.withLock {
            audioBuffers[source, default: []].append(contentsOf: samples)
            let queuedEnd = Double((consumedSamples[source] ?? 0)
                                   + (audioBuffers[source]?.count ?? 0)) / 16_000
                + (localClockOffset[source] ?? 0)
            receivedThrough[source] = max(receivedThrough[source] ?? 0, queuedEnd)
        }
    }

    // MARK: - Utterance Segmentation

    /// Pure utterance segmenter for the live loop (--profile-test drives it).
    ///
    /// Replaces the old fixed 2 s chunk emission, which cut ~75% of lines
    /// mid-sentence and decoded silence-bounded fragments that Whisper turned
    /// into hallucinations ("you", YouTube-outro residue). The segmenter only
    /// ever emits speech bounded by a real pause: leading silence is discarded
    /// outright (never decoded — the structural fix for silence hallucinations),
    /// and an utterance is cut when a sustained pause follows it, when it hits
    /// the length cap, or when the loop is draining at stop.
    enum Segmenter {
        /// Energy-frame size: 100 ms at 16 kHz. Pause detection resolution.
        static let frame = 1600
        /// Same mean-abs floor the loop has always used for "this is speech".
        static let silenceFloor: Float = 0.002
        /// 600 ms of continuous silence ends an utterance. Intra-word and
        /// clause gaps run shorter; sentence gaps run longer.
        // ponytail: fixed threshold — adaptive (speaker-rate) pausing if
        // fast-talker reports come in.
        static let pauseFrames = 6
        /// Speech islands under 300 ms surrounded by silence are clicks/noise:
        /// dropped without a decode.
        static let minSpeechSamples = 4800
        /// Forced cut for uninterrupted speech: bounds live latency and keeps a
        /// backlogged pass from decoding a minute as one wall of text (the old
        /// 2 s cap's job, at utterance scale). 12 s at 16 kHz.
        // ponytail: cap cuts mid-word; upgrade is cutting back at the
        // lowest-energy frame near the cap.
        static let maxSegmentSamples = 192_000
        /// Keep 100 ms of the pause on the cut so Whisper hears the word release.
        static let padFrames = 1

        /// One polling decision: discard `dropLeading` samples (silence — the
        /// consumed counter still advances so timestamps stay absolute), then
        /// cut `take` samples for decoding; `take == nil` means keep buffering.
        struct Cut: Equatable {
            var dropLeading: Int
            var take: Int?
        }

        static func nextCut(in buffer: [Float], draining: Bool) -> Cut {
            let n = buffer.count
            let frames = n / frame
            func frameEnergy(_ i: Int) -> Float {
                var sum: Float = 0
                for j in (i * frame)..<((i + 1) * frame) { sum += abs(buffer[j]) }
                return sum / Float(frame)
            }

            // Leading silence: whole silent frames before the first speech frame.
            var speechFrame: Int?
            for i in 0..<frames where frameEnergy(i) >= silenceFloor { speechFrame = i; break }
            guard let s = speechFrame else {
                // All silence so far. Keep the partial tail frame while live (it
                // may be the onset of a word); draining consumes everything so
                // the loop can reach empty and exit.
                return Cut(dropLeading: draining ? n : frames * frame, take: nil)
            }
            let drop = s * frame

            // Scan for the first sustained pause after speech starts.
            var silentRun = 0
            for i in s..<frames {
                if frameEnergy(i) < silenceFloor {
                    silentRun += 1
                    if silentRun == pauseFrames {
                        let speechEndFrame = i - pauseFrames + 1  // first frame of the pause
                        let speechLen = speechEndFrame * frame - drop
                        if speechLen < minSpeechSamples {
                            // Noise blip between silences: discard it with its pause.
                            return Cut(dropLeading: (i + 1) * frame, take: nil)
                        }
                        return Cut(dropLeading: drop, take: (speechEndFrame + padFrames) * frame - drop)
                    }
                } else {
                    silentRun = 0
                }
            }

            // Speech with no boundary yet.
            let speechLen = n - drop
            if speechLen >= maxSegmentSamples { return Cut(dropLeading: drop, take: maxSegmentSamples) }
            if draining { return Cut(dropLeading: drop, take: speechLen) }
            return Cut(dropLeading: drop, take: nil)
        }
    }

    // MARK: - Transcription Loop

    /// Start the continuous transcription loop
    @MainActor
    func startTranscribing(meetingStartTime: Date) {
        guard isReady else { return }
        // Never run two loops: cancel any prior task before starting a new one.
        transcriptionTask?.cancel()
        transcriptionTask = nil
        isTranscribing = true

        // Resolve the transcription backend for this session. Cloud backends
        // need their key; anything missing falls back to on-device with a
        // visible notice. (Deepgram streaming lands separately; until then it
        // behaves as local.)
        var backend = TranscriptionBackend.selected
        var groqKey: String?
        cloudNotice = nil
        self.meetingStartTime = meetingStartTime
        bufferLock.withLock {
            deepgramFailedSources = []
            localClockOffset = [:]
            consumedSamples = [.me: 0, .them: 0]
            completedThrough = [.me: 0, .them: 0]
            receivedThrough = [:]
            sawAudioSources = []
        }
        deepgramStreamers = [:]
        if backend == .groq {
            groqKey = APIKeyStore.load(account: TranscriptionBackend.groq.keychainAccount!)
            if groqKey?.isEmpty != false {
                backend = .local
                cloudNotice = "Groq key missing — using on-device Whisper"
            }
        }

        // Resolve the user's transcription language ("auto"/nil = auto-detect).
        let setting = UserDefaults.standard.string(forKey: "transcriptionLanguage")
        let language = (setting == nil || setting == "auto") ? nil : setting

        if backend == .deepgram {
            if let key = APIKeyStore.load(account: TranscriptionBackend.deepgram.keychainAccount!), !key.isEmpty {
                startDeepgram(apiKey: key, language: language)
            } else {
                backend = .local
                cloudNotice = "Deepgram key missing — using on-device Whisper"
            }
        }
        var decodeOptions = DecodingOptions(
            task: .transcribe,
            language: language,
            detectLanguage: language == nil
        )

        // Custom vocabulary: prime Whisper with the user's names/terms so it stops
        // mangling proper nouns (e.g. "LaunchEase" → "Lawn Cheese").
        primeGlossary(into: &decodeOptions)

        // Quality + anti-garbage decoding. We derive each segment's timestamps from
        // sample offsets, so suppress Whisper's special + timestamp tokens — they were
        // leaking into the live line as "<|0.00|> ... <|1.00|>" gibberish. The
        // thresholds trip a temperature fallback that breaks Whisper's repetition loops
        // (the "What's your name?" ×N hallucination on near-silent / noisy chunks), and
        // noSpeechThreshold drops silence instead of hallucinating over it.
        decodeOptions.skipSpecialTokens = true
        decodeOptions.withoutTimestamps = true
        decodeOptions.compressionRatioThreshold = 2.4
        decodeOptions.logProbThreshold = -1.0
        decodeOptions.noSpeechThreshold = 0.6
        decodeOptions.temperatureFallbackCount = 3

        // Detached on purpose: startTranscribing is @MainActor, and a plain
        // Task {} would inherit that, putting every energy scan and buffer copy
        // on the main thread for the whole call. The loop belongs on the global
        // executor; its UI-state writes already hop via MainActor explicitly.
        transcriptionTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                // isTranscribing == false flips the loop into drain mode: keep
                // consuming the backlog (whole utterances, down to the final
                // sub-frame tail) and exit once the buffers are empty. Capture
                // must already be stopped by then or the buffers keep growing —
                // that ordering is RecordingManager.stopRecording's contract.
                let draining = !self.isTranscribing
                var didWork = false

                for source in AudioSource.allCases {
                    // Pull at most one utterance for this stream under the lock.
                    // The segmenter decides the cut: leading silence is discarded
                    // (the consumed counter still advances, keeping timestamps
                    // absolute) and speech is only taken once a pause bounds it —
                    // or the cap / drain forces the cut. Freeing consumed audio
                    // keeps memory flat; the counter and clock offset ride along
                    // in the same lock.
                    let (chunk, startSample, clockOffset, dequeuedThrough): ([Float], Int, TimeInterval, TimeInterval) = self.bufferLock.withLock {
                        guard let buffered = self.audioBuffers[source], !buffered.isEmpty else { return ([], 0, 0, 0) }
                        let cut = Segmenter.nextCut(in: buffered, draining: draining)
                        let taken = cut.take.map { Array(buffered[cut.dropLeading ..< cut.dropLeading + $0]) } ?? []
                        let consumed = cut.dropLeading + taken.count
                        guard consumed > 0 else { return ([], 0, 0, 0) }
                        self.audioBuffers[source] = Array(buffered[consumed...])
                        let start = self.consumedSamples[source] ?? 0
                        self.consumedSamples[source] = start + consumed
                        let offset = self.localClockOffset[source] ?? 0
                        return (taken, start + cut.dropLeading, offset,
                                Double(start + consumed) / 16_000 + offset)
                    }
                    // No rolling preview: it re-decoded the entire pending
                    // utterance every 1.5 s per stream, and Whisper pads every
                    // decode to a fixed 30 s window — so live text cost 4-8x
                    // the compute of the committed transcript for pure display
                    // sugar. On fanless hardware that sustained load thermal-
                    // throttles the whole machine mid-call. The typing bubble
                    // shows dots (isHearingSpeech) until the utterance commits;
                    // the committed transcript is byte-identical either way.
                    guard !chunk.isEmpty else {
                        self.markCompleted(source: source, through: dequeuedThrough)
                        continue
                    }
                    didWork = true

                    let startTime = Double(startSample) / 16000.0 + clockOffset
                    let endTime = Double(startSample + chunk.count) / 16000.0 + clockOffset

                    // Backstop energy gate. The segmenter already refuses to cut
                    // silence, so this mostly guards drain-mode tails and keeps
                    // feeding the hallucination filter its energy signal.
                    let energy = chunk.reduce(into: Float(0)) { $0 += abs($1) } / Float(chunk.count)
                    guard energy > 0.002 else {
                        self.markCompleted(source: source, through: dequeuedThrough)
                        continue
                    }

                    // On-device decode — the default path, and the per-chunk
                    // fallback when a cloud backend hiccups (never lose a chunk).
                    func decodeLocally() async throws -> [(text: String, confidence: Float?)] {
                        guard let whisperKit = self.whisperKit else { return [] }
                        // No per-token interim streaming: each token callback
                        // hopped to the main actor and invalidated the live
                        // view — dozens of SwiftUI passes per second while the
                        // decoder ran. Words land at the utterance commit.
                        func decode(_ options: DecodingOptions) async throws -> [(text: String, confidence: Float?)] {
                            let result = try await whisperKit.transcribe(
                                audioArray: chunk,
                                decodeOptions: options
                            )
                            return result.map { transcription in
                                (transcription.text,
                                 transcription.segments.map(\.avgLogprob).reduce(0, +)
                                    / Float(max(transcription.segments.count, 1)))
                            }
                        }

                        let pieces = try await decode(decodeOptions)
                        guard self.glossaryActive else { return pieces }
                        // The glossary prompt can make Whisper swallow a clear
                        // utterance whole — empty text (or only the echoed
                        // prompt) for real speech. Deterministic repro:
                        // --liveloop-test with LIVELOOP_VOCAB on
                        // large-v3-turbo. The segmenter only cuts real speech,
                        // so an unusable decode of it is always wrong: decode
                        // once more without the prompt. Costs one extra pass
                        // only when the prompt misfired; that utterance just
                        // loses its spelling bias.
                        let usable = pieces.contains { piece in
                            let t = Self.cleaned(piece.text)
                            return !t.isEmpty && Self.strippingGlossaryEcho(t) != nil
                        }
                        if usable { return pieces }
                        if Self.loopTrace { print("TRACE \(source.label) glossary decode unusable — retrying bare") }
                        var bare = decodeOptions
                        bare.promptTokens = nil
                        bare.usePrefillPrompt = false
                        return try await decode(bare)
                    }

                    do {
                        let pieces: [(text: String, confidence: Float?)]
                        if backend == .groq, let groqKey {
                            do {
                                pieces = [(try await GroqTranscriber.transcribe(
                                    samples: chunk, language: language, apiKey: groqKey), nil)]
                            } catch {
                                NSLog("Parrot: Groq transcription failed — \(error.localizedDescription)")
                                await MainActor.run {
                                    self.cloudNotice = "Groq error — on-device fallback for failed chunks"
                                }
                                pieces = try await decodeLocally()
                            }
                        } else {
                            pieces = try await decodeLocally()
                        }

                        for piece in pieces {
                            let cleaned = Self.cleaned(piece.text)
                            if Self.loopTrace {
                                print(String(format: "TRACE %@ [%.2f-%.2f] raw=%@",
                                             source.label, startTime, endTime,
                                             piece.text.isEmpty ? "<empty>" : piece.text))
                            }
                            guard !cleaned.isEmpty else { continue }
                            // Silence hallucinations ("you", "Thank you.",
                            // "Okay.") flooded real transcripts — drop them
                            // when the chunk was near-silent.
                            guard !Self.isLikelyHallucination(cleaned, energy: energy) else { continue }
                            // Prompt leak: the glossary prompt comes back as
                            // "transcription", alone or prefixed onto real
                            // speech — keep the speech, drop only the echo.
                            guard let text = self.glossaryActive
                                ? Self.strippingGlossaryEcho(cleaned) : cleaned else { continue }

                            await MainActor.run {
                                // Clear the interim line — the text lives in the
                                // committed segment now; leaving it here kept a
                                // duplicate "typing" bubble on screen.
                                self.currentText = ""
                                self.onSegment?(TranscriptionResult(
                                    text: text,
                                    source: source,
                                    startTime: startTime,
                                    endTime: endTime,
                                    confidence: piece.confidence
                                ))
                            }
                        }
                    } catch {
                        print("Transcription error (\(source.label)): \(error)")
                    }
                    self.markCompleted(source: source, through: dequeuedThrough)
                }

                // Pause only when caught up. When a backlog exists (CPU spike or a
                // slow pass), keep draining bounded windows back-to-back so
                // transcription keeps pace with real time instead of falling
                // progressively behind — the regression that left the back half of a
                // call untranscribed.
                if !didWork {
                    if draining { break }  // buffers empty → fully drained, exit
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
    }

    /// Wire up one Deepgram socket per audio source. Interims drive the live
    /// line; finals become segments with Deepgram's stream-relative timestamps
    /// (= meeting-relative, streaming starts with the recording). Any failure
    /// flips the session to the local buffer/loop path.
    private func startDeepgram(apiKey: String, language: String?) {
        for source in AudioSource.allCases {
            let streamer = DeepgramStreamer()
            streamer.onInterim = { [weak self] text in
                let partial = Self.cleaned(text)
                guard !partial.isEmpty else { return }
                Task { @MainActor in self?.currentText = partial }
            }
            streamer.onFinal = { [weak self] text, start, end in
                guard let self else { return }
                let cleanedText = Self.cleaned(text)
                // energy 1.0: Deepgram runs its own voice-activity detection,
                // so only punctuation-only junk is filtered here.
                guard !cleanedText.isEmpty,
                      !Self.isLikelyHallucination(cleanedText, energy: 1.0) else { return }
                Task { @MainActor in
                    // Same as the Whisper path: the final belongs to the committed
                    // segment; the interim line must clear or it duplicates.
                    self.currentText = ""
                    self.onSegment?(TranscriptionResult(
                        text: cleanedText, source: source,
                        startTime: start, endTime: end, confidence: nil))
                }
            }
            streamer.onError = { [weak self] message in
                guard let self else { return }
                NSLog("Parrot: Deepgram stream failed (\(source.label)) — \(message)")
                // Only this stream falls back to local; the other socket keeps
                // streaming. Re-anchor before the first fallback sample lands.
                self.bufferLock.withLock { _ = self.deepgramFailedSources.insert(source) }
                self.reanchorLocalClock(source: source)
                Task { @MainActor in
                    self.cloudNotice = "Deepgram error — \(source.label) stream now on on-device Whisper"
                }
            }
            streamer.connect(apiKey: apiKey, language: language)
            deepgramStreamers[source] = streamer
        }
    }

    /// Re-anchor a stream's locally-derived timestamps to "now" in meeting time.
    /// Called when a stream falls off Deepgram mid-call and when the mic capture
    /// restarts after an input-device change — in both cases the sample counter
    /// wasn't ticking through the gap, so the next locally-transcribed segments
    /// would otherwise land minutes early.
    func reanchorLocalClock(source: AudioSource) {
        let elapsed = Date().timeIntervalSince(meetingStartTime)
        bufferLock.withLock {
            localClockOffset[source] = elapsed - Double(consumedSamples[source] ?? 0) / 16000.0
        }
    }

    /// Capture-relative time through which every active locally-decoded source
    /// has been consumed. The local clock offset is part of the timestamp
    /// contract: after a mic restart or Deepgram fallback, raw sample counts no
    /// longer line up with wall-clock meeting time.
    func consumedThrough(activeSources: Set<AudioSource>) -> TimeInterval {
        bufferLock.withLock {
            let active = activeSources.intersection(sawAudioSources).filter {
                deepgramFailedSources.contains($0) || deepgramStreamers[$0] == nil
            }
            guard !active.isEmpty else { return 0 }
            return active.map { completedThrough[$0] ?? 0 }.min() ?? 0
        }
    }

    /// Per-local-source decode targets at a handoff boundary. The target is
    /// capped at the last buffer received from that source, so a mic that died
    /// before the boundary cannot stall the gate, while its queued tail still
    /// must finish before post-processing starts.
    func completionTargets(through boundary: TimeInterval) -> [AudioSource: TimeInterval] {
        bufferLock.withLock {
            Dictionary(uniqueKeysWithValues: sawAudioSources.compactMap { source in
                guard deepgramFailedSources.contains(source) || deepgramStreamers[source] == nil,
                      let received = receivedThrough[source] else { return nil }
                return (source, min(boundary, received))
            })
        }
    }

    func hasCompleted(_ targets: [AudioSource: TimeInterval]) -> Bool {
        bufferLock.withLock {
            targets.allSatisfy { source, target in
                (completedThrough[source] ?? 0) >= target
            }
        }
    }

    func sourcesWithAudio() -> Set<AudioSource> {
        bufferLock.withLock { sawAudioSources }
    }

    private func markCompleted(source: AudioSource, through time: TimeInterval) {
        bufferLock.withLock {
            completedThrough[source] = max(completedThrough[source] ?? 0, time)
        }
    }

    /// True while a glossary prompt is active — gates the echo filter below.
    private var glossaryActive = false

    /// Prime Whisper with the user's custom glossary so proper nouns aren't
    /// mangled — shared by the live loop and file import. Fed as an initial
    /// prompt, the standard Whisper mechanism for biasing spelling.
    private func primeGlossary(into options: inout DecodingOptions) {
        glossaryActive = false
        let vocab = (UserDefaults.standard.string(forKey: "customVocabulary") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !vocab.isEmpty, let tokenizer = whisperKit?.tokenizer else { return }
        let terms = vocab
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return }
        let promptText = "Glossary: " + terms.joined(separator: ", ") + "."
        let tokens = tokenizer.encode(text: " " + promptText)
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        options.promptTokens = tokens
        options.usePrefillPrompt = true
        glossaryActive = true
    }

    /// Whisper leaks the initial prompt back as fake transcription on silent or
    /// noisy chunks — the live view showed "Glossary, Launchese, Uygar." bubbles
    /// during quiet stretches. Drop any segment that STARTS with "glossary":
    /// spoken vocab terms mid-sentence stay (only the structural echo matches).
    static func isGlossaryEcho(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
            .lowercased()
            .hasPrefix("glossary")
    }

    /// A prompt leak can PREFIX real speech, not only stand alone — turbo
    /// decoded a live utterance as "Glossary: Launchese, Uygar. However I'm
    /// worried…" and the drop-the-segment filter ate the real sentence
    /// (2026-08-01; `--liveloop-test <audio> large-v3-turbo` with
    /// LIVELOOP_VOCAB reproduces it deterministically). Utterance-sized
    /// segments made that loss a whole sentence, so: strip the leaked echo
    /// sentence, keep what follows. nil = pure echo, drop the segment.
    static func strippingGlossaryEcho(_ text: String) -> String? {
        guard isGlossaryEcho(text) else { return text }
        // The leak is one short "Glossary: …" sentence; cut through its
        // terminator and keep any real speech behind it.
        if let echo = text.range(of: #"^[^.!?]{0,120}[.!?]+"#, options: .regularExpression) {
            let rest = String(text[echo.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    // MARK: - File Import (whole-file, on-device)

    /// Transcribe a complete audio file on-device — the import path. Runs fully
    /// independent of the live streaming loop (never touches `isTranscribing` or
    /// the chunk buffers), so importing can't disturb an in-flight recording.
    /// Unlike the live loop it keeps Whisper's own segment timestamps: the loop
    /// derives them from sample offsets and suppresses them, but for a whole file
    /// Whisper's per-utterance boundaries are exactly what we want.
    /// WhisperKit loads + resamples any format (m4a/mp3/wav/aac/caf) to 16 kHz mono.
    func transcribeFile(url: URL) async throws -> [TranscriptionResult] {
        guard let whisperKit else { throw RecordingError.modelNotReady }

        let setting = UserDefaults.standard.string(forKey: "transcriptionLanguage")
        let language = (setting == nil || setting == "auto") ? nil : setting

        var options = DecodingOptions(
            task: .transcribe,
            language: language,
            detectLanguage: language == nil
        )
        // Same anti-garbage decoding as the live loop, but WITHOUT
        // `withoutTimestamps` — we want the segment timestamps here.
        options.skipSpecialTokens = true
        options.compressionRatioThreshold = 2.4
        options.logProbThreshold = -1.0
        options.noSpeechThreshold = 0.6
        options.temperatureFallbackCount = 3
        primeGlossary(into: &options)

        let results = try await whisperKit.transcribe(audioPath: url.path, decodeOptions: options)

        // One mixed track, so every segment is "Them"; diarization splits it later.
        return results.flatMap(\.segments).compactMap { segment in
            let cleaned = Self.cleaned(segment.text)
            guard !cleaned.isEmpty else { return nil }
            // Same glossary-prompt echo handling as the live loop.
            guard let text = glossaryActive
                ? Self.strippingGlossaryEcho(cleaned) : cleaned else { return nil }
            return TranscriptionResult(
                text: text,
                source: .them,
                startTime: Double(segment.start),
                endTime: Double(segment.end),
                confidence: segment.avgLogprob
            )
        }
    }

    /// Stop transcription, draining the buffered backlog first so the final words
    /// of the call (previously always dropped — the loop needed ≥2 s buffered)
    /// make it into the transcript. Await this before assembling the transcript.
    // ponytail: drain is uncapped — a hung whisper pass hangs stop; upgrade path
    // is a wall-clock cap + surfaced timeout.
    @MainActor
    func stopTranscribing() async {
        // Streaming backend: flush finals, then tear down. When the stream is
        // healthy, the chunk buffers only hold pre-connection audio — clear
        // them so the drain can't re-emit the call's first words at the end.
        if !deepgramStreamers.isEmpty {
            for streamer in deepgramStreamers.values { streamer.finish() }
            try? await Task.sleep(for: .seconds(1.2))  // grace for final results
            for streamer in deepgramStreamers.values { streamer.close() }
            // Clear the pre-connection buffers of streams that stayed on
            // Deepgram; a fallen-back stream's buffered tail still needs draining.
            bufferLock.withLock {
                for source in AudioSource.allCases where !deepgramFailedSources.contains(source) {
                    audioBuffers[source] = []
                }
            }
            deepgramStreamers = [:]
        }

        isTranscribing = false          // flips the loop into drain mode
        await transcriptionTask?.value  // deliberately not cancel(): let it finish
        transcriptionTask = nil

        bufferLock.withLock {
            audioBuffers = [.me: [], .them: []]
        }

        currentText = ""
        isHearingSpeech = false
    }

    /// The classic Whisper silence hallucinations — phrases the model invents
    /// verbatim on near-silent chunks (YouTube-outro residue in its training
    /// data). Matched against normalized text, only for low-energy chunks.
    static let hallucinationPhrases: Set<String> = [
        "you", "okay", "ok", "thank you", "thanks", "bye", "bye-bye",
        "thank you for watching", "thanks for watching", "hmm", "mm-hmm",
        "uh", "um", "the end", "subtitles by", "1", "2",
    ]

    /// True when a decoded chunk is almost certainly invented: punctuation-only
    /// text, or a known silence-hallucination phrase produced from a chunk that
    /// carried no confident speech energy. A real "Okay." at speaking volume
    /// (energy well above the floor) is never dropped.
    static func isLikelyHallucination(_ text: String, energy: Float) -> Bool {
        let normalized = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?…-—"))
            .trimmingCharacters(in: .whitespaces)
        if normalized.isEmpty { return true }  // "." and friends, at any volume
        // ponytail: 0.006 mean-abs ≈ room noise ceiling; speech runs 0.01+.
        // Tune here if quiet-talker reports come in.
        guard energy < 0.006 else { return false }
        return hallucinationPhrases.contains(normalized)
    }

    /// Strips any Whisper special/timestamp tokens (e.g. "<|startoftranscript|>",
    /// "<|0.00|>") that can leak into raw decoder text, and trims whitespace.
    static func cleaned(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"<\|[^|>]*\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
