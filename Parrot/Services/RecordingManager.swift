import SwiftUI
import SwiftData
import CoreGraphics
import AVFoundation

/// Orchestrates audio capture, transcription, and storage for a recording session.
@MainActor
@Observable
final class RecordingManager {
    let audioCaptureManager = AudioCaptureManager()
    let transcriptionEngine = TranscriptionEngine()
    let diarizationEngine = DiarizationEngine()
    // Routes to Claude / Ollama / a custom server per Settings → Copilot.
    let callAnalysisEngine = CallAnalysisEngine(provider: SwitchingAnalysisProvider())
    let knowledgeBase = KnowledgeBaseService()
    let profileStore = ProfileStore()
    /// Starts/stops recordings automatically for calendar events carrying a
    /// Google Meet link. Started in prepare(); gated by its Settings toggle.
    let autoRecorder = MeetingAutoRecorder()

    /// Optional one-line context for the next call, set from the dashboard.
    var nextCallBrief = ""

    private(set) var isRecording = false
    private(set) var recordingStartTime: Date?
    private(set) var elapsedTime: TimeInterval = 0
    private(set) var currentMeeting: Meeting?

    /// Guards against a second startRecording slipping in during the `await`s
    /// before isRecording is set — which would start a duplicate transcription
    /// loop and double every segment.
    private var isStarting = false
    /// Mirror of isStarting for the stop path: stop now drains the transcription
    /// backlog (seconds, not instant), so without this a double-stop would persist
    /// insights twice and run postProcess twice, and a start-during-stop would
    /// cancel the draining loop and share buffers with the old session. Readable
    /// so the live view can show a "Finalizing…" state.
    private(set) var isStopping = false
    private var timer: Timer?
    private var modelContext: ModelContext?

    /// Non-nil while a file import runs — drives the import banner in the UI.
    private(set) var importProgress: ImportProgress?

    struct ImportProgress: Equatable {
        var fileName: String
        var phase: Phase
        enum Phase {
            case transcribing, analyzing
            var label: String {
                switch self {
                case .transcribing: "Transcribing…"
                case .analyzing: "Analyzing…"
                }
            }
        }
    }

    init() {
        callAnalysisEngine.knowledgeBase = knowledgeBase
    }

    /// Dev-harness only (--help-shots): seed a live-looking session so
    /// LiveRecordingView can render offscreen without recording anything.
    func seedForSnapshot(meeting: Meeting, elapsed: TimeInterval, modelContext: ModelContext) {
        self.modelContext = modelContext
        currentMeeting = meeting
        elapsedTime = elapsed
        recordingStartTime = Date().addingTimeInterval(-elapsed)
        isRecording = true
    }

    /// Initialize and load the default WhisperKit model
    func prepare(modelContext: ModelContext) async {
        self.modelContext = modelContext
        recoverInterruptedRecordings(in: modelContext)
        profileStore.seedAndMigrateIfNeeded(context: modelContext, knowledgeBase: knowledgeBase)
        autoRecorder.start(recordingManager: self, modelContext: modelContext)
        await transcriptionEngine.loadModel(
            UserDefaults.standard.string(forKey: "whisperModel") ?? "base"
        )
    }

    /// A meeting left in `.recording` or `.processing` means the previous session was
    /// killed (crash or force-quit) before it could finish. The live transcript is
    /// already durable — `addSegment` saves every segment as it lands — so instead of
    /// discarding these, salvage the ones that captured any speech: re-run the normal
    /// post-call chain (diarization + report) on the surviving transcript and present
    /// them as recovered. Only truly empty orphans (killed before a word) stay failed.
    ///
    /// Runs at launch, off WhisperKit (transcript exists, diarization is energy-based,
    /// the report is a cloud call), so it needn't wait for the model.
    private func recoverInterruptedRecordings(in context: ModelContext) {
        guard let meetings = try? context.fetch(FetchDescriptor<Meeting>()) else { return }
        var changed = false
        for meeting in meetings where meeting.status == .recording || meeting.status == .processing {
            if meeting.segments.isEmpty {
                // Nothing was captured — the audio was never finalized and there's no
                // transcript to keep. Fail it, as before.
                meeting.status = .failed
                if meeting.errorMessage == nil {
                    meeting.errorMessage = "Recording was interrupted before it finished."
                }
            } else {
                // Salvageable: finish it in the background like a just-stopped call.
                meeting.wasRecovered = true
                meeting.status = .processing
                if meeting.duration == 0 {
                    meeting.duration = meeting.sortedSegments.last?.endTime ?? 0
                }
                let ref = meeting
                Task { await self.finishRecovery(meeting: ref) }
            }
            changed = true
        }
        if changed { try? context.save() }
    }

    private func finishRecovery(meeting: Meeting) async {
        // Audio is best-effort: a crash leaves the .caf header unfinalized, so it may
        // not open. If it doesn't, drop the paths so no dead player shows and
        // diarization is skipped cleanly (segments keep their live "Me"/"Them" labels).
        if let path = meeting.systemAudioPath.nilIfEmpty,
           (try? AVAudioFile(forReading: URL(fileURLWithPath: path))) == nil {
            meeting.systemAudioPath = ""
            meeting.micAudioPath = nil
            try? modelContext?.save()
        }

        // Same chain a clean stop runs: diarization refines speakers and sets .done;
        // the report runs when the copilot is configured. Coaching stays on — a
        // crashed live call still has a real per-segment "Me"/"Them" split.
        await postProcess(meeting: meeting)
        if callAnalysisEngine.isEnabled, callAnalysisEngine.provider.isConfigured,
           meeting.summary == nil {
            callAnalysisEngine.provider.resetUsage()
            await generateSummary(meeting: meeting)
        }
        writeAIUsage(meeting: meeting)
        meeting.status = .done
        try? modelContext?.save()
    }

    // MARK: - Recording Control

    /// The one shared entry point for every "start recording" button — checks
    /// permissions, then starts. Returns without starting (and without throwing)
    /// when a permission flow was triggered instead.
    func preflightPermissionsAndStart(modelContext: ModelContext) async throws {
        // Check Screen Recording permission BEFORE touching any ScreenCaptureKit
        // API (querying SCShareableContent while unauthorized pops the OS prompt
        // AND throws). PermissionFlow posts the single official prompt on a
        // first ask, or deep-links to Settings if previously denied — never both.
        guard PermissionFlow.requestScreenCapture() == .granted else { return }

        // Ensure the microphone is authorized so the user's own voice ("Me")
        // is captured. Without this the engine runs but feeds silence.
        // Non-fatal: system audio still records if denied.
        _ = await PermissionFlow.requestMicrophone()

        try await startRecording(modelContext: modelContext)
    }

    func startRecording(modelContext: ModelContext) async throws {
        self.modelContext = modelContext
        // Reject re-entry up front (before any await) so a double-trigger can't
        // start two recordings / two transcription loops. Also blocked while a
        // file import is running — both drive the same shared WhisperKit.
        guard !isRecording, !isStarting, !isStopping, importProgress == nil else { return }
        guard transcriptionEngine.isReady else {
            throw RecordingError.modelNotReady
        }
        isStarting = true
        defer { isStarting = false }

        // Create meeting
        let meeting = Meeting()
        modelContext.insert(meeting)

        // Persist active profile/brief/snapshot onto the meeting
        let profile = profileStore.activeProfile
        meeting.profile = profile
        meeting.brief = nextCallBrief.nilIfEmpty
        meeting.profileSnapshotData = profile.flatMap { try? JSONEncoder().encode($0.kinds) }

        // Set up audio capture. On failure, remove the just-inserted meeting —
        // otherwise it lingers as a ghost .recording row until the next launch's
        // orphan reconciliation flags it "interrupted".
        do {
            try await audioCaptureManager.startCapture()
        } catch {
            modelContext.delete(meeting)
            try? modelContext.save()
            throw error
        }
        meeting.systemAudioPath = audioCaptureManager.systemAudioURL?.path ?? ""
        meeting.micAudioPath = audioCaptureManager.micAudioURL?.path

        // Wire audio to transcription, tagged by stream (mic = Me, system = Them)
        audioCaptureManager.onAudioBuffer = { [weak self] buffer, source in
            self?.transcriptionEngine.appendAudio(buffer, source: source)
        }

        // A mid-call input-device change (dead AirPods, manual switch) rebuilds
        // the mic tap; the "Me" stream's clock must skip the dead gap or its
        // next locally-transcribed segments land minutes early.
        audioCaptureManager.onMicRestarted = { [weak self] in
            self?.transcriptionEngine.reanchorLocalClock(source: .me)
        }

        // Wire transcription output to storage. The live copilot loop is
        // deliberately NOT started: mid-call LLM cards are off in this build —
        // the AI budget goes to the post-call cleanup + report instead, and the
        // call itself runs with zero analysis overhead.
        transcriptionEngine.onSegment = { [weak self] result in
            Task { @MainActor in
                self?.addSegment(result)
            }
        }

        transcriptionEngine.startTranscribing(meetingStartTime: .now)
        callAnalysisEngine.provider.resetUsage()  // this call's token meter starts at zero

        currentMeeting = meeting
        recordingStartTime = .now
        isRecording = true

        // Start elapsed time timer
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.recordingStartTime else { return }
                self.elapsedTime = Date.now.timeIntervalSince(start)
            }
        }

        try modelContext.save()
    }

    func stopRecording() async {
        guard isRecording, !isStopping else { return }
        isStopping = true
        defer { isStopping = false }

        timer?.invalidate()
        timer = nil

        // Stop capture first so the transcription buffers stop growing and the
        // drain below terminates, and so both .caf files are finalized before
        // the post-processing task can read them.
        await audioCaptureManager.stopCapture()

        // Drain the transcription backlog so the call's final words land before
        // the transcript is assembled for the summary/coaching reports.
        await transcriptionEngine.stopTranscribing()
        // onSegment persists segments via Task { @MainActor } hops; yield once so
        // the last enqueued addSegment jobs run before we read segments back.
        await Task.yield()

        // Update meeting
        if let meeting = currentMeeting {
            meeting.duration = elapsedTime
            meeting.status = .processing
            try? modelContext?.save()

            // Post-processing chain, strictly sequential: the calendar lookup
            // names who the call was with, Claude cleans the transcript text
            // in place (optional, best-effort), and the report is generated
            // from the FINAL text — never from a transcript that's about to
            // change. postProcess stays for the import path; for live
            // two-track recordings it's a no-op that preserves Me/Them.
            let meetingRef = meeting
            Task {
                let counterpart = await CalendarLookup.counterpartName(
                    around: meetingRef.date, duration: meetingRef.duration)
                let cleaning = await self.cleanTranscript(
                    meeting: meetingRef, counterpart: counterpart)
                await self.postProcess(meeting: meetingRef)
                if self.callAnalysisEngine.isEnabled, self.callAnalysisEngine.provider.isConfigured {
                    await self.generateSummary(meeting: meetingRef, counterpartName: counterpart)
                }
                // Last in the chain so the meter has seen the summary/coaching calls too.
                self.writeAIUsage(meeting: meetingRef, cleaning: cleaning)
                meetingRef.status = .done
                try? self.modelContext?.save()
            }
        }

        isRecording = false
        elapsedTime = 0
        recordingStartTime = nil
    }

    // MARK: - File Import

    /// Import an existing audio file as a new meeting: copy it into app storage,
    /// transcribe the whole file on-device, then run the same diarization + report
    /// chain a live recording gets. Returns the created meeting (already inserted,
    /// status `.processing`) so the caller can select it; nil if it couldn't start.
    @discardableResult
    func importAudioFile(from pickedURL: URL, modelContext: ModelContext) -> Meeting? {
        self.modelContext = modelContext
        // One owner of WhisperKit at a time: refuse while recording or importing.
        guard !isRecording, !isStarting, !isStopping, importProgress == nil,
              transcriptionEngine.isReady else { return nil }

        // A user-picked file lives outside the sandbox — open the scope to copy it.
        let scoped = pickedURL.startAccessingSecurityScopedResource()
        defer { if scoped { pickedURL.stopAccessingSecurityScopedResource() } }

        let name = pickedURL.deletingPathExtension().lastPathComponent
        let ext = pickedURL.pathExtension.isEmpty ? "m4a" : pickedURL.pathExtension
        // Copy in, so playback and diarization survive the original moving/deleting.
        let dest = AudioCaptureManager.storageDirectory()
            .appendingPathComponent("import_\(Int(Date().timeIntervalSince1970)).\(ext)")
        do {
            try FileManager.default.copyItem(at: pickedURL, to: dest)
        } catch {
            NSLog("Parrot: import copy failed — \(error.localizedDescription)")
            return nil
        }

        // Land under the file's own date, so a recording from last week reads as
        // last week rather than "now".
        let fileDate = (try? pickedURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .now

        let meeting = Meeting(title: name, date: fileDate, systemAudioPath: dest.path)
        meeting.status = .processing
        let profile = profileStore.activeProfile
        meeting.profile = profile
        meeting.profileSnapshotData = profile.flatMap { try? JSONEncoder().encode($0.kinds) }
        modelContext.insert(meeting)
        try? modelContext.save()

        importProgress = ImportProgress(fileName: name, phase: .transcribing)
        let ref = meeting
        Task { await runImport(meeting: ref, audioURL: dest) }
        return meeting
    }

    private func runImport(meeting: Meeting, audioURL: URL) async {
        defer { importProgress = nil }

        // 1. Whole-file, on-device transcription. Every segment is "Them" (one
        //    mixed track, no mic channel to tag "Me"); diarization splits it below.
        do {
            let results = try await transcriptionEngine.transcribeFile(url: audioURL)
            guard !results.isEmpty else {
                meeting.status = .failed
                meeting.errorMessage = "No speech found in this file."
                try? modelContext?.save()
                return
            }
            for result in results {
                let segment = TranscriptSegment(
                    startTime: result.startTime, endTime: result.endTime,
                    text: result.text, speakerLabel: result.source.label,
                    confidence: result.confidence)
                modelContext?.insert(segment)
                segment.meeting = meeting
            }
            // Real audio length (trailing silence included) for stats/cost.
            if let file = try? AVAudioFile(forReading: audioURL) {
                meeting.duration = Double(file.length) / file.fileFormat.sampleRate
            } else {
                meeting.duration = results.last?.endTime ?? 0
            }
            try? modelContext?.save()
        } catch {
            meeting.status = .failed
            meeting.errorMessage = "Couldn't transcribe this file. \(error.localizedDescription)"
            try? modelContext?.save()
            return
        }

        // 2. Same post-call chain as a recording: diarization refines the speaker
        //    labels and flips status to .done; the summary runs when the copilot
        //    is configured. Coaching is skipped — no "Me" channel to measure.
        importProgress?.phase = .analyzing
        await postProcess(meeting: meeting)
        if callAnalysisEngine.isEnabled, callAnalysisEngine.provider.isConfigured {
            callAnalysisEngine.provider.resetUsage()
            await generateSummary(meeting: meeting, includeCoaching: false)
        }
        writeAIUsage(meeting: meeting, backendOverride: .local)
        meeting.status = .done
        try? modelContext?.save()
    }

    // MARK: - Deletion

    /// Deletes a meeting and its audio files. The only removal path in the app —
    /// without it storage grows forever. Refuses the active recording.
    func delete(_ meeting: Meeting) {
        guard !(isRecording && meeting.id == currentMeeting?.id) else { return }
        for path in [meeting.systemAudioPath.nilIfEmpty, meeting.micAudioPath?.nilIfEmpty].compactMap({ $0 }) {
            try? FileManager.default.removeItem(atPath: path)
        }
        if currentMeeting?.id == meeting.id { currentMeeting = nil }
        modelContext?.delete(meeting)
        try? modelContext?.save()
    }

    // MARK: - Segment Storage

    private func addSegment(_ result: TranscriptionEngine.TranscriptionResult) {
        // Use the live meeting object directly. The previous code looked the
        // meeting up via model(for: meetingID) where meetingID was captured before
        // the context was saved — i.e. a TEMPORARY identifier that goes stale after
        // save. Resolving that stale id returned a malformed object and assigning it
        // to segment.meeting tripped a SwiftData assertion (crash). currentMeeting
        // is the same registered instance in the same context, set before any
        // segment can arrive.
        guard let modelContext, let meeting = currentMeeting else { return }

        // Speaker bleed: without headphones the mic hears the speakers, the
        // AEC attenuates but can't always erase it, and the residual decodes —
        // the same sentence then lands twice, "Them" from system audio and
        // "Me" from the mic (and inflates diarization/talk-ratio). The system
        // copy is authoritative for anything both streams heard, so a Me
        // segment that near-duplicates a Them segment within a beat is echo,
        // whichever order they decoded in. (Surfaced by the speakers-playback
        // live test 2026-08-01; previously masked by the glossary decode bug.)
        let bleedWindow: TimeInterval = 2.5
        let neighbors = meeting.segments.filter { abs($0.startTime - result.startTime) <= bleedWindow }
        if result.source == .me,
           neighbors.contains(where: { $0.speakerLabel == AudioSource.them.label
               && Self.isEchoDuplicate($0.text, result.text) }) {
            return
        }
        if result.source == .them {
            for stored in neighbors where stored.speakerLabel == AudioSource.me.label
                && Self.isEchoDuplicate(stored.text, result.text) {
                modelContext.delete(stored)
            }
        }

        let segment = TranscriptSegment(
            startTime: result.startTime,
            endTime: result.endTime,
            text: result.text,
            speakerLabel: result.source.label,
            confidence: result.confidence
        )

        modelContext.insert(segment)
        segment.meeting = meeting
        try? modelContext.save()
    }

    /// Near-verbatim match for the echo-dedup above: Whisper decodes the bleed
    /// with small variances ("I am" vs "I'm"), so exact equality is too strict.
    /// High token overlap + the tight time window keeps a human genuinely
    /// echoing the other side (rare inside 2.5s) from being eaten.
    nonisolated static func isEchoDuplicate(_ a: String, _ b: String) -> Bool {
        func tokens(_ s: String) -> Set<String> {
            Set(s.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 1 })
        }
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return false }
        return Double(ta.intersection(tb).count) / Double(min(ta.count, tb.count)) >= 0.8
    }

    // MARK: - Post-Call Summary

    /// `includeCoaching` is false for imported files: a single mixed track has no
    /// "Me" channel, so talk-ratio/coaching would be measured against 0% and read
    /// as broken. The summary itself works fine from any transcript.
    /// `counterpartName` is the calendar invite's attendee(s) when the lookup
    /// found the meeting — the report then names the real person instead of
    /// the profile's generic "the other person".
    private func generateSummary(meeting: Meeting, includeCoaching: Bool = true,
                                 counterpartName: String? = nil) async {
        let segments = meeting.sortedSegments
        guard !segments.isEmpty else { return }

        let transcript = segments
            .map { "[\($0.formattedTimestamp)] \($0.speakerLabel ?? "Speaker"): \($0.text)" }
            .joined(separator: "\n")
        let insightTitles = meeting.sortedInsights.map { "\($0.style.label): \($0.title)" }
        let instructions = meeting.profile?.tone ?? (UserDefaults.standard.string(forKey: "copilotInstructions") ?? "")
        let counterpart = counterpartName ?? meeting.profile?.counterpart ?? "the other person"

        do {
            let summary = try await callAnalysisEngine.provider.summarize(
                transcript: transcript,
                insightTitles: insightTitles,
                instructions: instructions,
                counterpart: counterpart
            )
            meeting.summary = summary
            try? modelContext?.save()
        } catch {
            // Best-effort: the transcript and insights are already saved.
        }

        guard includeCoaching else { return }

        // Coaching + follow-ups report, with the user's real talk balance.
        let meWords = segments
            .filter { $0.speakerLabel == "Me" }
            .reduce(0) { $0 + $1.text.split(separator: " ").count }
        let totalWords = segments.reduce(0) { $0 + $1.text.split(separator: " ").count }
        let talkPercentMe = totalWords > 0 ? Int(Double(meWords) / Double(totalWords) * 100) : 0
        do {
            let coaching = try await callAnalysisEngine.provider.coachingReport(
                transcript: transcript,
                talkPercentMe: talkPercentMe,
                instructions: instructions,
                counterpart: counterpart
            )
            meeting.coaching = coaching
            try? modelContext?.save()
        } catch {
            // Best-effort.
        }
    }

    // MARK: - Post-call cleanup

    /// Clean the live transcript's TEXT through Claude — the replacement for
    /// the old Groq audio re-polish. Segments are updated in place, so every
    /// timestamp and Me/Them speaker label survives untouched; only the words
    /// change. Opt-in ("polishAfterCall", the same toggle as before) and
    /// best-effort: any failure keeps the live transcript. Returns the token
    /// usage for the cost row, nil when cleanup didn't run.
    private func cleanTranscript(meeting: Meeting, counterpart: String?) async -> AITokenTotals? {
        guard UserDefaults.standard.bool(forKey: "polishAfterCall"),
              let key = APIKeyStore.load(), !key.isEmpty,
              let modelContext else { return nil }

        let segments = meeting.sortedSegments
        guard !segments.isEmpty else { return nil }

        let lines = segments.map { (speaker: $0.speakerLabel ?? "Them", text: $0.text) }
        let (cleaned, usage) = await TranscriptCleaner.clean(
            lines: lines, counterpart: counterpart, apiKey: key)
        for (index, segment) in segments.enumerated() {
            if let text = cleaned[index] { segment.text = text }
        }
        try? modelContext.save()
        NSLog("Parrot: transcript cleaned — \(cleaned.count)/\(segments.count) lines updated")
        return usage.calls > 0 ? usage : nil
    }

    // MARK: - AI usage snapshot

    /// Freezes this call's AI usage (report tokens + transcription audio
    /// seconds + cleanup tokens) onto the meeting so the detail view can show
    /// what it cost.
    private func writeAIUsage(meeting: Meeting, cleaning: AITokenTotals? = nil,
                              backendOverride: TranscriptionBackend? = nil) {
        var usage = AIUsage()
        // ponytail: reads the copilot provider/model at stop time, same accepted
        // mid-call-switch edge as the transcription backend below.
        if let switching = callAnalysisEngine.provider as? SwitchingAnalysisProvider {
            let live = switching.liveUsage
            usage.copilotModel = live.model
            usage.copilotProvider = live.provider
            usage.copilot = live.totals
            // Second bucket only when reports ran on a different backend.
            if let reports = switching.reportsUsage {
                usage.reportsModel = reports.model
                usage.reportsProvider = reports.provider
                usage.reports = reports.totals
            }
        } else {
            usage.copilotModel = CopilotProviderKind.activeModelName
            usage.copilotProvider = CopilotProviderKind.selected.rawValue
            usage.copilot = callAnalysisEngine.provider.usageTotals
        }
        // ponytail: reads the backend setting at stop time; a mid-call engine
        // switch or cloud→local fallback mislabels one estimated row. Import
        // passes an override since it's always on-device regardless of the setting.
        usage.transcriptionBackend = (backendOverride ?? TranscriptionBackend.selected).rawValue
        usage.transcriptionSeconds = meeting.duration
        usage.transcriptionTracks = meeting.micAudioPath?.nilIfEmpty != nil ? 2 : 1
        if let cleaning {
            usage.cleaning = cleaning
            usage.cleaningModel = TranscriptCleaner.model
        }
        meeting.aiUsageData = try? JSONEncoder().encode(usage)
        try? modelContext?.save()
    }

    // MARK: - Post-Processing

    private func postProcess(meeting: Meeting) async {
        // Status stays .processing here — the calling chain flips .done after
        // the post-call REPORT finishes, so the UI can say "writing report…"
        // instead of the misleading "no report was generated".
        guard let audioPath = meeting.systemAudioPath.nilIfEmpty,
              FileManager.default.fileExists(atPath: audioPath) else { return }

        // Live recordings with a mic track already carry the strongest speaker
        // split there is: "Me" came from the microphone, "Them" from system
        // audio — two physically separate streams. The energy-based diarizer
        // below is a placeholder that alternates "Speaker 1/2" labels, which
        // would DEGRADE that ground-truth split. Only single-track audio
        // (file imports, mic-less recordings) has anything to gain from it.
        guard meeting.micAudioPath?.nilIfEmpty == nil else { return }

        do {
            let audioURL = URL(fileURLWithPath: audioPath)
            let speakerSegments = try await diarizationEngine.diarize(audioURL: audioURL)

            // Assign speaker labels to transcript segments by time overlap.
            // "Me" segments come from the mic stream and are already attributed;
            // diarization only refines who's who within the system audio ("Them").
            for transcriptSegment in meeting.segments {
                guard transcriptSegment.speakerLabel != "Me" else { continue }
                let bestMatch = speakerSegments.max { a, b in
                    overlap(a, transcriptSegment) < overlap(b, transcriptSegment)
                }
                if let match = bestMatch, overlap(match, transcriptSegment) > 0 {
                    transcriptSegment.speakerLabel = match.speakerLabel
                }
            }
            try? modelContext?.save()
        } catch {
            // Diarization is a refinement pass; the audio and transcript are
            // already saved. Keep the generic "Them" labels rather than showing
            // a perfectly good meeting as failed.
            NSLog("Parrot: diarization failed — \(error.localizedDescription)")
            try? modelContext?.save()
        }
    }

    /// Calculate time overlap between a speaker segment and transcript segment
    private nonisolated func overlap(
        _ speaker: DiarizationEngine.SpeakerSegmentResult,
        _ transcript: TranscriptSegment
    ) -> TimeInterval {
        let overlapStart = max(speaker.startTime, transcript.startTime)
        let overlapEnd = min(speaker.endTime, transcript.endTime)
        return max(0, overlapEnd - overlapStart)
    }

    var formattedElapsedTime: String {
        let hours = Int(elapsedTime) / 3600
        let minutes = (Int(elapsedTime) % 3600) / 60
        let seconds = Int(elapsedTime) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

enum RecordingError: LocalizedError {
    case modelNotReady

    var errorDescription: String? {
        switch self {
        case .modelNotReady: "WhisperKit model is not loaded yet. Please wait."
        }
    }
}
