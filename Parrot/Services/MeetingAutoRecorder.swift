import EventKit
import Foundation
import SwiftData

/// Hands-free recording: watches the user's calendar and starts a recording
/// when an event carrying a Google Meet link begins — no button press. The
/// recording stops on its own once no Meet event is ongoing anymore AND the
/// call has gone quiet (meetings routinely run past their scheduled end, so
/// the scheduled end alone is never trusted).
///
/// The app must be running (menu bar is enough). Auto-start only fires when
/// Screen Recording is already granted and the Whisper model is loaded — it
/// never pops permission prompts on its own except the one-time Calendar ask.
@MainActor
@Observable
final class MeetingAutoRecorder {
    static let enabledKey = "autoRecordMeetings"
    /// On by default in this build — the whole point is zero-touch capture.
    /// Settings → Transcription has the off switch.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// After the last Meet event ends, stop once the room has been quiet this
    /// long — speech keeps the recording alive however long the call overruns.
    static let quietStopAfter: TimeInterval = 240
    /// Backstop: never keep recording longer than this past the last Meet
    /// event's end, speech or not (screenshare audio, music, a forgotten tab).
    static let overrunHardCap: TimeInterval = 45 * 60

    private weak var recordingManager: RecordingManager?
    private var modelContext: ModelContext?
    private var timer: Timer?
    private let store = EKEventStore()
    private var calendarAskInFlight = false
    /// Occurrence keys already started (or manually dismissed) this app run —
    /// a manual Stop must not be answered with an immediate auto-restart.
    private var handledOccurrences: Set<String> = []
    /// Non-nil while a recording THIS scheduler started is running; manual
    /// recordings are never auto-stopped.
    private var autoOccurrenceKey: String?
    private var lastSpeechAt = Date()
    /// First tick at which no Meet event was ongoing anymore (drives the cap).
    private var meetEndedAt: Date?

    func start(recordingManager: RecordingManager, modelContext: ModelContext) {
        self.recordingManager = recordingManager
        self.modelContext = modelContext
        timer?.invalidate()
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() async {
        guard Self.isEnabled, let manager = recordingManager, let modelContext else { return }

        // Calendar access — one ask, then silent.
        if EKEventStore.authorizationStatus(for: .event) != .fullAccess {
            guard !calendarAskInFlight else { return }
            calendarAskInFlight = true
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            guard granted else { return }
        }

        let now = Date()
        // Events overlapping "now": window reaches back for long meetings.
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-4 * 3600),
            end: now.addingTimeInterval(60),
            calendars: nil
        )
        let ongoingMeet = store.events(matching: predicate).filter { event in
            guard !event.isAllDay, let start = event.startDate, let end = event.endDate,
                  start <= now, end > now else { return false }
            return Self.containsMeetLink(
                title: event.title, location: event.location,
                notes: event.notes, urlString: event.url?.absoluteString)
        }

        // While recording, keep the speech clock fresh from the live audio
        // levels and the committed transcript — either stream counts.
        if manager.isRecording {
            if manager.audioCaptureManager.audioLevel > 0.003
                || manager.audioCaptureManager.micLevel > 0.003 {
                lastSpeechAt = now
            }
            if let start = manager.recordingStartTime,
               let lastSegmentEnd = manager.currentMeeting?.segments.map(\.endTime).max() {
                lastSpeechAt = max(lastSpeechAt, start.addingTimeInterval(lastSegmentEnd))
            }
        }

        // The user pressed Stop on an auto-started recording: respect it —
        // mark everything currently ongoing as handled so it doesn't restart.
        if !manager.isRecording, autoOccurrenceKey != nil {
            autoOccurrenceKey = nil
            for event in ongoingMeet { handledOccurrences.insert(Self.occurrenceKey(event)) }
        }

        if manager.isRecording {
            // Auto-stop applies only to recordings this scheduler started.
            guard autoOccurrenceKey != nil else { return }
            if !ongoingMeet.isEmpty {
                meetEndedAt = nil
                return
            }
            let endedAt = meetEndedAt ?? now
            meetEndedAt = endedAt
            let quiet = now.timeIntervalSince(lastSpeechAt) > Self.quietStopAfter
            let capped = now.timeIntervalSince(endedAt) > Self.overrunHardCap
            if quiet || capped {
                autoOccurrenceKey = nil
                meetEndedAt = nil
                NSLog("Parrot: auto-stopping — Meet event over, \(quiet ? "room quiet" : "overrun cap")")
                await manager.stopRecording()
            }
            return
        }

        // Auto-start: first unhandled ongoing Meet event. Only when the model
        // is loaded and Screen Recording is already granted — this path must
        // never surprise the user with an OS prompt mid-meeting.
        guard !manager.isStopping, manager.transcriptionEngine.isReady,
              CGPreflightScreenCaptureAccess() else { return }
        guard let event = ongoingMeet.first(where: {
            !handledOccurrences.contains(Self.occurrenceKey($0))
        }) else { return }

        let key = Self.occurrenceKey(event)
        handledOccurrences.insert(key)
        do {
            try await manager.startRecording(modelContext: modelContext)
            autoOccurrenceKey = key
            meetEndedAt = nil
            lastSpeechAt = now
            // Name the meeting after the invite so the sidebar reads like a
            // calendar, not "Meeting at 14:03".
            if let title = event.title?.trimmingCharacters(in: .whitespaces).nilIfEmpty {
                manager.currentMeeting?.title = title
                try? modelContext.save()
            }
            NSLog("Parrot: auto-started recording for \"\(event.title ?? "meeting")\"")
        } catch {
            NSLog("Parrot: auto-start failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Pure helpers (harness-tested)

    /// Whether an event carries a Google Meet link anywhere the invite can
    /// put one (Google Calendar surfaces it in location, notes, or the URL).
    nonisolated static func containsMeetLink(
        title: String?, location: String?, notes: String?, urlString: String?
    ) -> Bool {
        [title, location, notes, urlString]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains("meet.google.com") }
    }

    /// Recurring events share one eventIdentifier across occurrences — key on
    /// identifier + occurrence start so today's standup doesn't block
    /// tomorrow's.
    nonisolated static func occurrenceKey(identifier: String?, start: Date?) -> String {
        "\(identifier ?? "?")@\(Int(start?.timeIntervalSince1970 ?? 0))"
    }

    private nonisolated static func occurrenceKey(_ event: EKEvent) -> String {
        occurrenceKey(identifier: event.eventIdentifier, start: event.startDate)
    }
}
