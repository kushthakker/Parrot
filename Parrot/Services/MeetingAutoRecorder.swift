import EventKit
import Foundation
import ScreenCaptureKit
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
    /// If a Meet window was visible during this auto-recording and then stays
    /// gone, stop sooner once speech is also absent. Requiring both signals
    /// avoids treating a quiet room or a transient window-list failure alone
    /// as proof that the user left the call.
    nonisolated static let leftCallQuietStopAfter: TimeInterval = 90
    /// Keep an imminent successor on the uninterrupted handoff path. Longer
    /// gaps can stop safely and let normal calendar auto-start resume later.
    nonisolated static let successorLookahead: TimeInterval = 5 * 60
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
    private var autoEvent: (key: String, end: Date, title: String?)?
    private var lastSpeechAt = Date()
    /// First tick at which no Meet event was ongoing anymore (drives the cap).
    private var meetEndedAt: Date?
    /// Ticks await (calendar ask, start/stop recording) long enough for the
    /// next timer fire to interleave on the main actor — one tick at a time.
    private var tickInFlight = false
    private var wasRecordingLastTick = false
    private var ongoingKeysAtLastRecordingTick: Set<String> = []
    private var suppressNextTransitionMark = false
    private var handoffFailures: [String: Int] = [:]
    private var hasSeenMeetWindow = false
    private var observedMeetWindowIDs: Set<CGWindowID> = []
    private var meetWindowMissingSince: Date?

    var isManagingCurrentRecording: Bool { autoEvent != nil }

    func start(recordingManager: RecordingManager, modelContext: ModelContext) {
        self.recordingManager = recordingManager
        self.modelContext = modelContext
        wasRecordingLastTick = recordingManager.isRecording
        timer?.invalidate()
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() async {
        guard Self.isEnabled, let manager = recordingManager, let modelContext else { return }
        // Never prompt for Calendar while onboarding is still walking the
        // user through the screen/mic grants.
        guard UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") else { return }
        guard !tickInFlight else { return }
        tickInFlight = true
        defer { tickInFlight = false }

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
            end: now.addingTimeInterval(Self.successorLookahead),
            calendars: nil
        )
        let meetEvents = store.events(matching: predicate).filter { event in
            guard !event.isAllDay, let start = event.startDate, let end = event.endDate,
                  start <= now.addingTimeInterval(Self.successorLookahead),
                  end > now else { return false }
            return Self.containsMeetLink(
                title: event.title, location: event.location,
                notes: event.notes, urlString: event.url?.absoluteString)
        }
        let ongoingMeet = meetEvents.filter { ($0.startDate ?? .distantFuture) <= now }

        let ongoingKeys = Set(ongoingMeet.map(Self.occurrenceKey))
        let recordingNow = manager.isRecording && !manager.isStopping
        let transition = Self.transitionMark(
            wasRecording: wasRecordingLastTick,
            isRecording: recordingNow,
            suppress: suppressNextTransitionMark,
            ongoingAtLastRecordingTick: ongoingKeysAtLastRecordingTick
        )
        if !transition.handled.isEmpty { handledOccurrences.formUnion(transition.handled) }
        suppressNextTransitionMark = transition.suppressAfter
        if wasRecordingLastTick && !recordingNow {
            autoEvent = nil
            hasSeenMeetWindow = false
            observedMeetWindowIDs = []
            meetWindowMissingSince = nil
        }
        if recordingNow { ongoingKeysAtLastRecordingTick = ongoingKeys }
        // Preserve the state sampled before any await. If the user presses Stop
        // while a ScreenCaptureKit query is suspended, the next tick must still
        // observe the true → false transition and mark the covered occurrence.
        defer { wasRecordingLastTick = recordingNow }

        // While recording, keep the speech clock fresh from the live audio
        // levels and the committed transcript — either stream counts.
        if manager.isRecording {
            if manager.audioCaptureManager.audioLevel > 0.003
                || manager.audioCaptureManager.micLevel > 0.003 {
                lastSpeechAt = now
            }
            if let nowElapsed = manager.captureElapsed,
               let lastSegmentEnd = manager.recordedSpeechIntervals().map(\.upperBound).max() {
                lastSpeechAt = max(lastSpeechAt,
                                   now.addingTimeInterval(lastSegmentEnd - nowElapsed))
            }
        }

        // A normal Stop keeps isRecording true while Whisper drains. It is not
        // a handoff candidate, and retrying B during that window could exhaust
        // the three-attempt guard before the engine is available again.
        if manager.isStopping { return }

        if manager.isRecording {
            // Auto-stop applies only to recordings this scheduler started.
            guard var current = autoEvent else { return }

            if let refreshed = ongoingMeet.first(where: {
                Self.occurrenceKey($0) == current.key
            }) {
                current.end = refreshed.endDate
                current.title = refreshed.title
                autoEvent = current
            }

            let pendingNext = meetEvents
                .filter {
                    let key = Self.occurrenceKey($0)
                    return key != current.key && !handledOccurrences.contains(key)
                        && Self.isProtectedSuccessor(
                            start: $0.startDate, currentEnd: current.end, now: now)
                }
                .min { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
            let next = pendingNext.flatMap {
                ($0.startDate ?? .distantFuture) <= now ? $0 : nil
            }

            // ScreenCaptureKit is already authorized for system-audio capture.
            // A failed query is unknown, not "window missing"; only a successful
            // window snapshot may advance or reset the early-stop clock.
            let activeMeetingID = manager.currentMeeting?.id
            let content = try? await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: false)
            guard manager.isRecording, !manager.isStopping,
                  manager.currentMeeting?.id == activeMeetingID,
                  autoEvent?.key == current.key else {
                if manager.currentMeeting?.id != activeMeetingID {
                    autoEvent = nil
                    hasSeenMeetWindow = false
                    observedMeetWindowIDs = []
                    meetWindowMissingSince = nil
                }
                return
            }
            let onScreenWindowTitles = content?.windows
                .filter(\.isOnScreen).compactMap(\.title) ?? []
            let meetWindows = content?.windows.filter {
                $0.title.map(Self.isMeetWindowTitle) ?? false
            } ?? []
            if content != nil {
                if !meetWindows.isEmpty {
                    hasSeenMeetWindow = true
                    observedMeetWindowIDs.formUnion(meetWindows.map(\.windowID))
                }
                let existingWindowIDs = Set(content?.windows.map(\.windowID) ?? [])
                if !observedMeetWindowIDs.isDisjoint(with: existingWindowIDs) {
                    meetWindowMissingSince = nil
                } else if hasSeenMeetWindow {
                    meetWindowMissingSince = meetWindowMissingSince ?? now
                }
            } else {
                // Unknown breaks the continuous-absence proof. Keep the fact
                // that Meet was seen, but require a fresh 90-second run.
                meetWindowMissingSince = nil
            }

            if let next,
               let nowElapsed = manager.captureElapsed,
               let recordingStart = manager.currentSpanStartElapsed {
                let signal = Self.titleSignal(
                    windowTitles: onScreenWindowTitles,
                    currentTitle: current.title,
                    nextTitle: next.title
                )
                let speech = manager.recordedSpeechIntervals()
                let horizon = manager.transcriptionEngine.isStreaming
                    ? nowElapsed : manager.decodedThrough
                let inputs = SplitInputs(
                    now: nowElapsed,
                    horizon: horizon,
                    recordingStart: recordingStart,
                    currentEnd: nowElapsed + current.end.timeIntervalSince(now),
                    nextStart: nowElapsed + (next.startDate ?? now).timeIntervalSince(now),
                    speech: speech,
                    lastSpeechAt: nowElapsed - now.timeIntervalSince(lastSpeechAt),
                    titleSignal: signal
                )
                let decision = Self.splitDecision(inputs)
                if decision.fire, let boundary = decision.boundary {
                    let key = Self.occurrenceKey(next)
                    do {
                        if let meeting = try await manager.handoffRecording(
                            modelContext: modelContext,
                            title: next.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                            boundaryElapsed: boundary,
                            provisional: decision.provisional
                        ) {
                            autoEvent = (key, next.endDate, next.title)
                            handledOccurrences.insert(key)
                            handoffFailures[key] = nil
                            lastSpeechAt = now
                            observedMeetWindowIDs = signal == .showsNext
                                ? Set(meetWindows.map(\.windowID)) : []
                            hasSeenMeetWindow = !observedMeetWindowIDs.isEmpty
                            meetWindowMissingSince = nil
                            manager.markAutoStarted(meeting)
                            NSLog("Parrot: handed off recording to \"\(next.title ?? "meeting")\"")
                            return
                        }
                    } catch {
                        NSLog("Parrot: handoff failed — \(error.localizedDescription)")
                    }
                    let failures = (handoffFailures[key] ?? 0) + 1
                    handoffFailures[key] = failures
                    if failures >= 3 {
                        handledOccurrences.insert(key)
                        handoffFailures[key] = nil
                        NSLog("Parrot: handoff gave up after 3 attempts for \"\(next.title ?? "meeting")\"")
                    }
                }
            }

            if Self.shouldStopAfterLeaving(
                   sawMeetWindow: hasSeenMeetWindow,
                   windowMissingFor: meetWindowMissingSince.map { now.timeIntervalSince($0) },
                   quietFor: now.timeIntervalSince(lastSpeechAt),
                   hasNextMeeting: pendingNext != nil
               ) {
                autoEvent = nil
                meetEndedAt = nil
                hasSeenMeetWindow = false
                observedMeetWindowIDs = []
                meetWindowMissingSince = nil
                NSLog("Parrot: auto-stopping — Meet window gone and room quiet")
                await manager.stopRecording()
                return
            }

            if !ongoingMeet.isEmpty {
                meetEndedAt = nil
                return
            }
            let endedAt = meetEndedAt ?? now
            meetEndedAt = endedAt
            let quiet = now.timeIntervalSince(lastSpeechAt) > Self.quietStopAfter
            let capped = now.timeIntervalSince(endedAt) > Self.overrunHardCap
            if quiet || capped {
                autoEvent = nil
                meetEndedAt = nil
                hasSeenMeetWindow = false
                observedMeetWindowIDs = []
                meetWindowMissingSince = nil
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
        guard let event = ongoingMeet
            .filter({ !handledOccurrences.contains(Self.occurrenceKey($0)) })
            .min(by: { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) })
        else { return }

        let key = Self.occurrenceKey(event)
        handledOccurrences.insert(key)
        do {
            try await manager.startRecording(modelContext: modelContext)
            autoEvent = (key, event.endDate, event.title)
            meetEndedAt = nil
            lastSpeechAt = now
            hasSeenMeetWindow = false
            observedMeetWindowIDs = []
            meetWindowMissingSince = nil
            manager.markAutoStarted(manager.currentMeeting)
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

    enum TitleSignal: Equatable {
        case showsCurrent, showsNext, unknown
    }

    struct SplitInputs {
        var now: TimeInterval
        var horizon: TimeInterval
        var recordingStart: TimeInterval
        var currentEnd: TimeInterval
        var nextStart: TimeInterval
        var speech: [ClosedRange<TimeInterval>]
        var lastSpeechAt: TimeInterval
        var titleSignal: TitleSignal
    }

    struct SplitDecision {
        var fire: Bool
        var boundary: TimeInterval?
        var provisional: Bool
    }

    /// First credible decoded silence of at least 30 seconds in the search
    /// window. `horizon` is a completed-decode watermark, never wall clock, so
    /// undecoded audio cannot masquerade as trailing silence.
    nonisolated static func splitGap(_ input: SplitInputs) -> ClosedRange<TimeInterval>? {
        let floor = max(input.recordingStart, input.nextStart - 600)
        guard input.horizon > floor else { return nil }
        let clipped = input.speech.compactMap { interval -> ClosedRange<TimeInterval>? in
            let lower = max(floor, interval.lowerBound)
            let upper = min(input.horizon, interval.upperBound)
            return upper >= lower ? lower...upper : nil
        }.sorted { $0.lowerBound < $1.lowerBound }
        guard var previous = clipped.first else {
            return input.horizon - floor >= 30 ? floor...input.horizon : nil
        }
        var gaps: [ClosedRange<TimeInterval>] = []
        if previous.lowerBound - floor >= 30 {
            gaps.append(floor...previous.lowerBound)
        }
        for interval in clipped.dropFirst() {
            if interval.lowerBound <= previous.upperBound {
                previous = previous.lowerBound...max(previous.upperBound, interval.upperBound)
            } else {
                if interval.lowerBound - previous.upperBound >= 30 {
                    gaps.append(previous.upperBound...interval.lowerBound)
                }
                previous = interval
            }
        }
        if input.horizon - previous.upperBound >= 30 {
            gaps.append(previous.upperBound...input.horizon)
        }
        // Do not resurrect an ordinary pause far back inside A merely because
        // later A speech exists. A credible switch gap must reach to within a
        // minute of the scheduled boundary (or cross it); early-leave trailing
        // silence still qualifies because its upper edge reaches the horizon.
        let boundary = min(input.currentEnd, input.nextStart)
        return gaps.first { $0.upperBound >= boundary - 60 }
    }

    nonisolated static func splitDecision(_ input: SplitInputs) -> SplitDecision {
        let gap = splitGap(input)
        if input.titleSignal == .showsNext {
            return SplitDecision(
                fire: true,
                boundary: gap.map { $0.lowerBound + 2 } ?? input.now,
                provisional: gap == nil
            )
        }
        guard input.titleSignal != .showsCurrent, input.now >= input.currentEnd else {
            return SplitDecision(fire: false, boundary: nil, provisional: false)
        }
        if let gap {
            if input.speech.contains(where: { $0.lowerBound >= gap.lowerBound + 30 }) {
                return SplitDecision(fire: true, boundary: gap.lowerBound + 2, provisional: false)
            }
            if input.lastSpeechAt <= gap.lowerBound + 5,
               input.now - gap.lowerBound >= 45 {
                return SplitDecision(fire: true, boundary: gap.lowerBound + 2, provisional: false)
            }
        }
        if input.now >= input.nextStart + 300 {
            return SplitDecision(
                fire: true,
                boundary: gap.map { $0.lowerBound + 2 } ?? input.now,
                provisional: gap == nil
            )
        }
        return SplitDecision(fire: false, boundary: nil, provisional: false)
    }

    nonisolated static func titleSignal(
        windowTitles: [String],
        currentTitle: String?,
        nextTitle: String?
    ) -> TitleSignal {
        let meetTitles = windowTitles.filter(isMeetWindowTitle)
        func matches(_ candidate: String?) -> Bool {
            guard let candidate = candidate?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  candidate.count >= 4 else { return false }
            return meetTitles.contains {
                $0.range(of: candidate, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        if matches(nextTitle) { return .showsNext }
        if matches(currentTitle) { return .showsCurrent }
        return .unknown
    }

    nonisolated static func hasMeetWindow(_ windowTitles: [String]) -> Bool {
        windowTitles.contains(where: isMeetWindowTitle)
    }

    nonisolated static func isMeetWindowTitle(_ title: String) -> Bool {
        title.range(
            of: #"(?:\bgoogle\s+meet\b|^\s*meet\s*[-–—|:])"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    nonisolated static func isProtectedSuccessor(
        start: Date?, currentEnd: Date, now: Date
    ) -> Bool {
        guard let start else { return false }
        if start <= now { return true }
        return start.timeIntervalSince(now) <= successorLookahead
            && abs(start.timeIntervalSince(currentEnd)) <= 60
    }

    nonisolated static func shouldStopAfterLeaving(
        sawMeetWindow: Bool,
        windowMissingFor: TimeInterval?,
        quietFor: TimeInterval,
        hasNextMeeting: Bool
    ) -> Bool {
        guard sawMeetWindow, !hasNextMeeting,
              let windowMissingFor else { return false }
        return windowMissingFor >= leftCallQuietStopAfter
            && quietFor >= leftCallQuietStopAfter
    }

    nonisolated static func transitionMark(
        wasRecording: Bool,
        isRecording: Bool,
        suppress: Bool,
        ongoingAtLastRecordingTick: Set<String>
    ) -> (handled: Set<String>, suppressAfter: Bool) {
        guard wasRecording, !isRecording else {
            return ([], suppress)
        }
        if suppress { return ([], false) }
        return (ongoingAtLastRecordingTick, false)
    }

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
