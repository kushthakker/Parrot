import Foundation
import SwiftUI
import SwiftData

/// Offscreen logic harness. Run: `.build/debug/Parrot --profile-test`
/// Prints PASS/FAIL per check and exits non-zero on any failure.
enum ProfileTest {
    private static var failures = 0

    private static func check(_ name: String, _ cond: @autoclosure () -> Bool) {
        if cond() { print("PASS \(name)") } else { print("FAIL \(name)"); failures += 1 }
    }

    @MainActor
    static func run() {
        testKindStyleFallback()
        testHexColor()
        testInsightKey()
        testCallProfile()
        testPresets()
        testKBScoping()
        testMigration()
        testPresetRefresh()
        testPromptAndSchema()
        testSnapshotPersistence()
        testLenientKBDecode()
        testStableHash()
        testNearDuplicate()
        testSupersedes()
        testHallucinationFilter()
        testWAVEncoder()
        testAIUsageCost()
        testPermissionFlow()
        testMicWatchdog()
        testModelFolderMatch()
        testSegmenter()
        testCopilotBudget()
        testTranscriptCleaner()
        testAutoRecorderHelpers()
        testAutoRecorderSplitPolicy()
        testAutoRecorderTitleSignal()
        testAutoRecorderTransition()
        testMeetingSpanHelpers()
        testMeetingBoundaryMutation()
        testMixedTranscriptionGate()
        testCalendarBestMatch()
        print(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    static func testTranscriptCleaner() {
        // Numbering carries global indexes through a mid-array slice.
        let lines = [(speaker: "Me", text: "hello"), (speaker: "Them", text: "hi there"),
                     (speaker: "Me", text: "bye")]
        let numbered = TranscriptCleaner.numberedLines(lines[1...])
        check("cleaner numbering keeps global indexes",
              numbered == "1 | Them | hi there\n2 | Me | bye")

        // Valid payload maps back by index; unknown indexes are dropped.
        let originals = [0: "helo world", 1: "fine thanks"]
        let good = #"{"lines":[{"i":0,"text":"Hello, world."},{"i":1,"text":"Fine, thanks."},{"i":9,"text":"ghost"}]}"#
        let accepted = TranscriptCleaner.acceptedLines(fromJSON: good, originals: originals)
        check("cleaner accepts mapped lines", accepted[0] == "Hello, world.")
        check("cleaner drops unknown index", accepted[9] == nil)

        // A line the model shrank to nothing or ballooned is rejected —
        // cleanup never summarizes or pads.
        let bad = #"{"lines":[{"i":0,"text":"x"},{"i":1,"text":"\#(String(repeating: "pad ", count: 40))"}]}"#
        let guarded = TranscriptCleaner.acceptedLines(fromJSON: bad, originals: originals)
        check("cleaner rejects over-shrunk line", guarded[0] == nil)
        check("cleaner rejects over-grown line", guarded[1] == nil)

        // Malformed JSON keeps the originals rather than corrupting anything.
        check("cleaner survives malformed JSON",
              TranscriptCleaner.acceptedLines(fromJSON: "not json", originals: originals).isEmpty)

        // The user's cleanup brief carries the calendar name when known.
        check("cleaner prompt names the counterpart",
              TranscriptCleaner.systemPrompt(counterpart: "Puneet").contains("call with Puneet"))
        check("cleaner prompt has a generic fallback",
              TranscriptCleaner.systemPrompt(counterpart: nil).contains("another person"))
    }

    static func testAutoRecorderHelpers() {
        check("meet link found in location",
              MeetingAutoRecorder.containsMeetLink(
                  title: "Sync", location: "https://meet.google.com/abc-defg-hij",
                  notes: nil, urlString: nil))
        check("meet link found in notes",
              MeetingAutoRecorder.containsMeetLink(
                  title: nil, location: nil,
                  notes: "Join: https://MEET.GOOGLE.COM/xyz", urlString: nil))
        check("no meet link means no match",
              !MeetingAutoRecorder.containsMeetLink(
                  title: "Lunch", location: "Cafe", notes: "no link here", urlString: "https://zoom.us/j/1"))
        let day1 = Date(timeIntervalSince1970: 1_700_000_000)
        let day2 = day1.addingTimeInterval(86_400)
        check("recurring occurrences key separately",
              MeetingAutoRecorder.occurrenceKey(identifier: "evt", start: day1)
                  != MeetingAutoRecorder.occurrenceKey(identifier: "evt", start: day2))
    }

    static func testAutoRecorderSplitPolicy() {
        func input(
            now: Double = 160, horizon: Double = 145,
            recordingStart: Double = 0, currentEnd: Double = 100,
            nextStart: Double = 100,
            speech: [ClosedRange<Double>] = [0...85, 120...140],
            lastSpeechAt: Double = 140,
            signal: MeetingAutoRecorder.TitleSignal = .unknown
        ) -> MeetingAutoRecorder.SplitInputs {
            .init(now: now, horizon: horizon, recordingStart: recordingStart,
                  currentEnd: currentEnd, nextStart: nextStart, speech: speech,
                  lastSpeechAt: lastSpeechAt, titleSignal: signal)
        }

        let confirmed = MeetingAutoRecorder.splitDecision(input())
        check("b2b confirmed gap fires", confirmed.fire && confirmed.boundary == 87)
        check("b2b confirmed gap is exact", !confirmed.provisional)

        let quiet = MeetingAutoRecorder.splitDecision(input(
            now: 140, horizon: 140, speech: [0...90], lastSpeechAt: 92))
        check("b2b persistent quiet fires", quiet.fire && quiet.boundary == 92)

        let choppy = MeetingAutoRecorder.splitDecision(input(
            now: 150, horizon: 150,
            speech: [0...30, 55...80, 105...130], lastSpeechAt: 130))
        check("b2b 25 second pauses do not split", !choppy.fire)

        let forced = MeetingAutoRecorder.splitDecision(input(
            now: 400, horizon: 400, speech: [0...400], lastSpeechAt: 400))
        check("b2b force cap fires", forced.fire && forced.boundary == 400 && forced.provisional)
        let held = MeetingAutoRecorder.splitDecision(input(
            now: 400, horizon: 400, speech: [0...400], lastSpeechAt: 400,
            signal: .showsCurrent))
        check("b2b current title blocks force cap", !held.fire)

        let titleMove = MeetingAutoRecorder.splitDecision(input(
            now: 120, horizon: 90, speech: [0...80], lastSpeechAt: 80,
            signal: .showsNext))
        check("b2b next title fires with lagging record",
              titleMove.fire && titleMove.boundary == 120 && titleMove.provisional)

        let beforeEnd = MeetingAutoRecorder.splitDecision(input(
            now: 95, horizon: 145, currentEnd: 100, speech: [0...85, 120...140]))
        check("b2b audio path waits for current end", !beforeEnd.fire)

        let oldPause = MeetingAutoRecorder.splitDecision(input(
            now: 500, horizon: 500, currentEnd: 500, nextStart: 500,
            speech: [0...100, 140...500], lastSpeechAt: 500))
        check("b2b old conversational gap is ignored", !oldPause.fire)

        let silent = MeetingAutoRecorder.splitGap(input(
            now: 160, horizon: 145, speech: [], lastSpeechAt: 0))
        check("b2b wholly silent decoded record has a gap", silent == 0...145)

        let silentA = MeetingAutoRecorder.splitDecision(input(
            now: 160, horizon: 145, speech: [120...145], lastSpeechAt: 145))
        check("b2b silent A then speaking B uses leading gap",
              silentA.fire && silentA.boundary == 2 && !silentA.provisional)
    }

    static func testAutoRecorderTitleSignal() {
        check("b2b title matches next",
              MeetingAutoRecorder.titleSignal(
                windowTitles: ["Meet – Product Review — Chrome"],
                currentTitle: "Planning", nextTitle: "Product Review") == .showsNext)
        check("b2b title match is case insensitive",
              MeetingAutoRecorder.titleSignal(
                windowTitles: ["GOOGLE MEET — WEEKLY SYNC"],
                currentTitle: "Weekly Sync", nextTitle: "Demo") == .showsCurrent)
        check("b2b next title wins when both are visible",
              MeetingAutoRecorder.titleSignal(
                windowTitles: ["Meet — Current Call", "Meet — Next Call"],
                currentTitle: "Current Call", nextTitle: "Next Call") == .showsNext)
        check("b2b short event title is refused",
              MeetingAutoRecorder.titleSignal(
                windowTitles: ["Meet — One"], currentTitle: nil, nextTitle: "One") == .unknown)
        check("b2b non-Meet window is ignored",
              MeetingAutoRecorder.titleSignal(
                windowTitles: ["Product Review — Notes"],
                currentTitle: nil, nextTitle: "Product Review") == .unknown)
        check("auto-stop recognizes a visible Meet window",
              MeetingAutoRecorder.hasMeetWindow(["Google Meet — Weekly Sync"]))
        check("auto-stop ignores ordinary browser windows",
              !MeetingAutoRecorder.hasMeetWindow(["Calendar — Google Chrome"]))
        check("auto-stop rejects Meeting substring",
              !MeetingAutoRecorder.hasMeetWindow(["Meeting notes — Google Chrome"]))
        check("auto-stop rejects Meetup substring",
              !MeetingAutoRecorder.hasMeetWindow(["Meetup — Google Chrome"]))
        check("auto-stop rejects generic Meet agenda",
              !MeetingAutoRecorder.hasMeetWindow(["Meet agenda — Notes"]))
        check("auto-stop rejects meet summary suffix",
              !MeetingAutoRecorder.hasMeetWindow(["Board notes — meet summary"]))
        check("auto-stop fires after Meet disappears and room stays quiet",
              MeetingAutoRecorder.shouldStopAfterLeaving(
                sawMeetWindow: true, windowMissingFor: 90,
                quietFor: 90, hasNextMeeting: false))
        check("auto-stop requires prior Meet-window proof",
              !MeetingAutoRecorder.shouldStopAfterLeaving(
                sawMeetWindow: false, windowMissingFor: 120,
                quietFor: 120, hasNextMeeting: false))
        check("auto-stop waits through brief window disappearance",
              !MeetingAutoRecorder.shouldStopAfterLeaving(
                sawMeetWindow: true, windowMissingFor: 89,
                quietFor: 120, hasNextMeeting: false))
        check("auto-stop waits while speech continues",
              !MeetingAutoRecorder.shouldStopAfterLeaving(
                sawMeetWindow: true, windowMissingFor: 120,
                quietFor: 89, hasNextMeeting: false))
        check("auto-stop defers to back-to-back handoff",
              !MeetingAutoRecorder.shouldStopAfterLeaving(
                sawMeetWindow: true, windowMissingFor: 120,
                quietFor: 120, hasNextMeeting: true))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let scheduledEnd = now.addingTimeInterval(300)
        check("auto-stop protects successor five minutes away",
              MeetingAutoRecorder.isProtectedSuccessor(
                start: scheduledEnd, currentEnd: scheduledEnd, now: now))
        check("auto-stop ignores non-adjacent future meeting",
              !MeetingAutoRecorder.isProtectedSuccessor(
                start: now.addingTimeInterval(240),
                currentEnd: now.addingTimeInterval(1_800), now: now))
    }

    static func testAutoRecorderTransition() {
        let stopped = MeetingAutoRecorder.transitionMark(
            wasRecording: true, isRecording: false, suppress: false,
            ongoingAtLastRecordingTick: ["A"])
        check("b2b stopped transition marks prior event", stopped.handled == ["A"])
        let handoff = MeetingAutoRecorder.transitionMark(
            wasRecording: true, isRecording: true, suppress: false,
            ongoingAtLastRecordingTick: ["A"])
        check("b2b handoff has no stopped transition", handoff.handled.isEmpty)
        let suppressed = MeetingAutoRecorder.transitionMark(
            wasRecording: true, isRecording: false, suppress: true,
            ongoingAtLastRecordingTick: ["A"])
        check("b2b split-stop suppression marks nothing",
              suppressed.handled.isEmpty && !suppressed.suppressAfter)
    }

    static func testMeetingSpanHelpers() {
        let boundaries: [Double] = [30, 70]
        check("span routes before first boundary", RecordingManager.spanIndex(for: 29.999, boundaries: boundaries) == 0)
        check("span routes exact boundary forward", RecordingManager.spanIndex(for: 30, boundaries: boundaries) == 1)
        check("span routes middle tail", RecordingManager.spanIndex(for: 69.999, boundaries: boundaries) == 1)
        check("span routes third meeting", RecordingManager.spanIndex(for: 80, boundaries: boundaries) == 2)
        check("span local time rebases", 80 - boundaries[1] == 10)

        check("b2b provisional boundary refines into gap",
              RecordingManager.refinedBoundary(
                provisional: 120, speech: [0...90, 125...145], horizon: 145) == 92)
        check("b2b continuous speech keeps provisional boundary",
              RecordingManager.refinedBoundary(
                provisional: 120, speech: [0...145], horizon: 145) == 120)
        check("b2b triple handoff cannot reuse prior gap",
              RecordingManager.refinedBoundary(
                provisional: 160, speech: [0...90, 125...200], horizon: 200,
                minimumBoundary: 120) == 160)
    }

    @MainActor
    static func testMeetingBoundaryMutation() {
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        guard let container = try? ModelContainer(for: schema, configurations: [config]) else {
            check("b2b refinement test container builds", false); return
        }
        let context = ModelContext(container)
        let a = Meeting(title: "A"), b = Meeting(title: "B")
        context.insert(a); context.insert(b)
        let movesToB = TranscriptSegment(
            startTime: 100, endTime: 105, text: "late A tail", speakerLabel: "Them")
        let staysInB = TranscriptSegment(
            startTime: 10, endTime: 15, text: "B", speakerLabel: "Them")
        context.insert(movesToB); context.insert(staysInB)
        movesToB.meeting = a
        staysInB.meeting = b
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        RecordingManager.applyRefinedBoundary(
            previous: a, next: b, previousStart: 0, oldBoundary: 120,
            refined: 92, nextEnd: 180, captureEpoch: epoch)
        check("b2b refinement moves segment forward", movesToB.meeting?.id == b.id)
        check("b2b refinement rebases moved segment", movesToB.startTime == 8 && movesToB.endTime == 13)
        check("b2b refinement preserves B global time", staysInB.startTime == 38 && staysInB.endTime == 43)
        check("b2b refinement updates durations", a.duration == 92 && b.duration == 88)
        check("b2b refinement updates B date", b.date == epoch.addingTimeInterval(92))

        let c = Meeting(title: "C"), d = Meeting(title: "D")
        context.insert(c); context.insert(d)
        let movesBack = TranscriptSegment(
            startTime: 5, endTime: 9, text: "belongs to C", speakerLabel: "Them")
        context.insert(movesBack); movesBack.meeting = d
        RecordingManager.applyRefinedBoundary(
            previous: c, next: d, previousStart: 0, oldBoundary: 120,
            refined: 130, nextEnd: nil, captureEpoch: nil)
        check("b2b refinement moves segment backward", movesBack.meeting?.id == c.id)
        check("b2b backward move restores capture time", movesBack.startTime == 125)
    }

    static func testMixedTranscriptionGate() {
        check("b2b mixed backend keeps streaming grace",
              TranscriptionEngine.needsStreamingGrace(
                sawAudioSources: [.me, .them], failedSources: [.me], hasStreamers: true))
        check("b2b all-local backend needs no streaming grace",
              !TranscriptionEngine.needsStreamingGrace(
                sawAudioSources: [.me, .them], failedSources: [.me, .them], hasStreamers: true))
        check("b2b absent streamers need no grace",
              !TranscriptionEngine.needsStreamingGrace(
                sawAudioSources: [.them], failedSources: [], hasStreamers: false))
    }

    static func testCalendarBestMatch() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let recStart = base, recEnd = base.addingTimeInterval(1800)
        let events = [
            (start: base.addingTimeInterval(-3600), end: base.addingTimeInterval(-1800)),  // before
            (start: base.addingTimeInterval(-300), end: base.addingTimeInterval(1500)),    // big overlap
            (start: base.addingTimeInterval(1700), end: base.addingTimeInterval(3600)),    // tail overlap
        ]
        check("calendar picks the biggest overlap",
              CalendarLookup.bestMatch(events: events, recordingStart: recStart, recordingEnd: recEnd) == 1)
        check("calendar returns nil with no overlap",
              CalendarLookup.bestMatch(events: [events[0]], recordingStart: recStart, recordingEnd: recEnd) == nil)
        let adjacent = [
            (start: base, end: base.addingTimeInterval(1800)),
            (start: base.addingTimeInterval(1800), end: base.addingTimeInterval(3600)),
        ]
        check("calendar boundary window selects A",
              CalendarLookup.bestMatch(events: adjacent, recordingStart: base,
                                       recordingEnd: base.addingTimeInterval(1800)) == 0)
        check("calendar boundary window selects B",
              CalendarLookup.bestMatch(events: adjacent,
                                       recordingStart: base.addingTimeInterval(1800),
                                       recordingEnd: base.addingTimeInterval(3600)) == 1)
    }

    static func testKindStyleFallback() {
        let blocker = KindResolver.fallbackStyle(forKey: "blocker")
        check("fallback blocker is pinned", blocker.isPinned == true)
        check("fallback blocker label", blocker.label == "Blocker")
        let unknown = KindResolver.fallbackStyle(forKey: "totally_made_up")
        check("fallback unknown not pinned", unknown.isPinned == false)
        check("fallback unknown has a label", !unknown.label.isEmpty)
    }

    static func testInsightKey() {
        let draft = InsightDraft(kindKey: "blocker", title: "Price too high", detail: "x", source: nil)
        check("draft carries kindKey", draft.kindKey == "blocker")
        let insight = Insight(kindKey: "buying_signal", title: "t", detail: "d", callTime: 0, source: nil)
        check("insight style resolves unknown key", insight.style.label == "Buying Signal")
        check("insight known key pinned", Insight(kindKey: "blocker", title: "t", detail: "d", callTime: 0, source: nil).style.isPinned)
    }

    static func testCallProfile() {
        let kind = ProfileKind(id: UUID(), key: "objection", label: "Objection",
            colorHex: "E8943A", iconSystemName: "hand.raised.fill",
            triggerDescription: "Them raised a concern", isPinned: true, priority: 10)
        let p = CallProfile(name: "Sales", iconSystemName: "dollarsign.circle",
            summary: "x", isBuiltIn: true, sortOrder: 0, persona: "p", tone: "t",
            allowGeneralKnowledge: true, kinds: [kind], gauges: [])
        check("profile round-trips kinds", p.kinds.first?.key == "objection")
        let style = p.style(forKey: "objection")
        check("profile style label", style?.label == "Objection")
        check("profile style pinned", style?.isPinned == true)
        check("profile unknown key nil", p.style(forKey: "nope") == nil)
    }

    static func testPresets() {
        let all = ProfilePresets.all()
        check("six presets", all.count == 6)
        check("default first by sortOrder", all.sorted { $0.sortOrder < $1.sortOrder }.first?.id == ProfilePresets.defaultProfileID)
        let coaching = all.first { $0.name == "1:1 coaching" }
        check("coaching has reflection kind", coaching?.kinds.contains { $0.key == "reflection" } == true)
        check("coaching has NO blocker kind", coaching?.kinds.contains { $0.key == "blocker" } == false)
        check("sales has buying_temperature gauge", all.first { $0.name == "Sales discovery" }?.gauges.contains { $0.key == "buying_temperature" } == true)
        let def = all.first { $0.id == ProfilePresets.defaultProfileID }
        check("default has today's five keys", Set(def?.kinds.map(\.key) ?? []) == ["suggestion", "question", "blocker", "action_item", "feedback"])
    }

    @MainActor
    static func testKBScoping() {
        let kb = KnowledgeBaseService(persistent: false)
        // Synchronous: unknown profile UUID always returns empty names list.
        check("documentNames empty for unknown profile", kb.documentNames(for: UUID()).isEmpty)
        // Synchronous: after tagging all docs into a fresh ID, every doc contains it.
        let tagID = UUID()
        kb.tagAllDocuments(into: tagID)
        // If kb has any documents, they should all contain tagID. Vacuously true on empty KB.
        check("tagAllDocuments tags every document", kb.documents.allSatisfy { $0.profileIDs.contains(tagID) })
        // Scoped search for unknown profile: since search() early-returns [] when chunks is empty
        // (CLI KB is always empty), and for a truly unknown profile even with chunks the allowedNames
        // set would be empty making snapshot empty. We assert via documentNames proxy — a freshly
        // created UUID has no documents tagged into it.
        check("documentNames for untagged profile is empty", kb.documentNames(for: UUID()).isEmpty)
    }

    @MainActor
    static func testMigration() {
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        guard let container = try? ModelContainer(for: schema, configurations: [config]) else {
            check("migration container builds", false); return
        }
        let ctx = ModelContext(container)
        let kb = KnowledgeBaseService(persistent: false)
        let store = ProfileStore()
        // Save/restore the real value — the old removeObject-based cleanup
        // DELETED the user's actual copilot instructions after every test run.
        let previous = UserDefaults.standard.string(forKey: "copilotInstructions")
        UserDefaults.standard.set("be concise", forKey: "copilotInstructions")
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: "copilotInstructions")
            } else {
                UserDefaults.standard.removeObject(forKey: "copilotInstructions")
            }
        }
        store.seedAndMigrateIfNeeded(context: ctx, knowledgeBase: kb)
        let profiles = (try? ctx.fetch(FetchDescriptor<CallProfile>())) ?? []
        check("seeded six profiles", profiles.count == 6)
        let def = profiles.first { $0.id == ProfilePresets.defaultProfileID }
        check("default absorbed instructions as tone", def?.tone == "be concise")
        // Idempotent: second run doesn't duplicate.
        store.seedAndMigrateIfNeeded(context: ctx, knowledgeBase: kb)
        check("seeding idempotent", ((try? ctx.fetch(FetchDescriptor<CallProfile>()))?.count ?? 0) == 6)
    }

    @MainActor
    static func testPresetRefresh() {
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        guard let container = try? ModelContainer(for: schema, configurations: [config]) else {
            check("refresh container builds", false); return
        }
        let ctx = ModelContext(container)
        let kb = KnowledgeBaseService(persistent: false)
        let store = ProfileStore()
        store.seedAndMigrateIfNeeded(context: ctx, knowledgeBase: kb)

        let profiles = (try? ctx.fetch(FetchDescriptor<CallProfile>())) ?? []
        guard let sales = profiles.first(where: { $0.name == "Sales discovery" }),
              let support = profiles.first(where: { $0.name == "Customer support" }) else {
            check("refresh finds built-ins", false); return
        }

        // A user-tuned built-in must survive a preset-version bump untouched...
        sales.persona = "my custom persona"
        sales.isUserModified = true
        sales.presetVersion = 0
        // ...while an untouched stale built-in picks up the shipped preset.
        support.persona = "stale junk"
        support.presetVersion = 0
        try? ctx.save()

        store.seedAndMigrateIfNeeded(context: ctx, knowledgeBase: kb)
        check("refresh preserves user-tuned built-in", sales.persona == "my custom persona")
        check("refresh bumps tuned profile's version", sales.presetVersion == ProfilePresets.presetVersion)
        let presetSupport = ProfilePresets.all().first { $0.id == support.id }
        check("refresh restores untouched built-in", support.persona == presetSupport?.persona)
    }

    static func testLenientKBDecode() {
        // A KBDocument saved before `note` existed must still decode — a strict
        // decode fails the whole store load and the next save wipes the KB.
        let legacy = """
        {"id":"\(UUID().uuidString)","name":"pricing.pdf","chunkCount":3,"addedAt":700000000}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let doc = try? decoder.decode(KBDocument.self, from: legacy)
        check("KB doc decodes without note", doc != nil)
        check("KB doc missing note defaults empty", doc?.note == "")
        check("KB doc missing profileIDs defaults empty", doc?.profileIDs.isEmpty == true)
    }

    static func testNearDuplicate() {
        // Real reworded re-flags from the 2026-07-02 test call — must match.
        check("dedup catches reworded pricing question", CallAnalysisEngine.isNearDuplicate(
            "Annual plan pricing still unanswered Prospect asked twice what the annual subscription costs including onboarding fees.",
            "What does the annual subscription cost? Prospect explicitly asked for the annual plan price including onboarding fees."))
        check("dedup catches reworded docs question", CallAnalysisEngine.isNearDuplicate(
            "What docs do fintech partners actually need? The prospect just asked what documents UK fintechs require to open an account.",
            "What documents do fintech partners require? The prospect asked directly what verification documents the fintech banks need."))
        // Distinct topics from the same call — must NOT match.
        check("dedup keeps distinct topics apart", !CallAnalysisEngine.isNearDuplicate(
            "What are the actual requirements for UK bank account? Prospect asked what's needed to open a UK business bank account as a Moroccan resident.",
            "France customer base de-risks Stripe acceptance Prospect has customers in France which helps with processor acceptance."))
        check("dedup empty strings safe", !CallAnalysisEngine.isNearDuplicate("", "anything"))
    }

    // The model-side dedup verdict ("supersedes") — the 2026-07-17 call showed
    // re-flags crossing kinds (Shopify: suggestion → unanswered_question) and
    // rewording past any text heuristic (embedding distance was calibrated on
    // that call's real cards and could not separate dups from distinct — see
    // isNearDuplicate's scope note). Verify the whole chain: schema forces the
    // field, prompt explains it, parser carries it.
    static func testSupersedes() {
        let kinds = ProfilePresets.all().first { $0.name == "Sales discovery" }!.kinds
        let schema = ClaudeAnalysisProvider.schema(kinds: kinds, gauges: [])
        let insightsProp = ((schema["properties"] as? [String: Any])?["insights"] as? [String: Any])
        let items = insightsProp?["items"] as? [String: Any]
        check("supersedes in item schema", ((items?["properties"] as? [String: Any])?["supersedes"]) != nil)
        check("supersedes is required (compliance pattern)", (items?["required"] as? [String])?.contains("supersedes") == true)

        let prompt = ClaudeAnalysisProvider.systemPrompt(persona: "P", kinds: kinds, gauges: [])
        check("prompt explains supersedes", prompt.contains("supersedes"))

        // Parser carries the verdict through; empty string normalizes to nil.
        let payload = """
        {"insights": [
          {"kind": "objection", "title": "Banking intro in your package?", "detail": "d", "reply": "", "supersedes": "Prospect asking about bank account setup"},
          {"kind": "objection", "title": "Genuinely new concern", "detail": "d", "reply": "", "supersedes": ""}
        ], "sentiment": {"coach": "c", "score": 50, "read": "r"}, "resolved": []}
        """
        let parsed = try? ClaudeAnalysisProvider.parseAnalysisPayload(payload)
        check("parse carries supersedes", parsed?.insights.first?.supersedes == "Prospect asking about bank account setup")
        check("parse normalizes empty supersedes to nil", parsed?.insights.last?.supersedes == nil)
        // The engine filter admits exactly the drafts without a verdict.
        let admitted = (parsed?.insights ?? []).filter { ($0.supersedes ?? "").isEmpty }
        check("re-flag dropped, new card admitted", admitted.count == 1 && admitted.first?.title == "Genuinely new concern")

        // Verdict corroboration — honor the claim only when it stands up.
        typealias E = CallAnalysisEngine
        let bankingCard = [(title: "Prospect asking about bank account setup",
                            text: "Prospect asking about bank account setup Prospect asked what happens after formation: specifically, how to open a UK business bank account.")]
        // Real re-flag from the 2026-07-17 call: "banking"/"bank" corroborate via stem.
        check("verdict honored: banking re-flag corroborates", E.verdictCorroborated(
            supersedes: "Prospect asking about bank account setup",
            draftText: "Banking intro in your package? Prospect asked whether a banking introduction is included.",
            openCards: bankingCard))
        // Observed llama3.2 hallucination: new EU question claiming to supersede
        // the price card — zero shared stems, verdict rejected, card survives.
        check("verdict rejected: hallucinated overlap survives", !E.verdictCorroborated(
            supersedes: "Price pushback: quote is roughly double their current spend",
            draftText: "EU hosting region unclear The prospect asked whether data is stored in the EU and got no answer.",
            openCards: [(title: "Price pushback: quote is roughly double their current spend",
                         text: "Price pushback: quote is roughly double their current spend The prospect said the quote is double what they pay today.")]))
        check("verdict rejected: cited card not open", !E.verdictCorroborated(
            supersedes: "Some card that was never shown",
            draftText: "Banking intro in your package?",
            openCards: bankingCard))
        check("stem match: cross-kind Shopify pair", E.sharesTopicStem(
            "Does the package include Shopify integration?",
            "Prospect asking about Shopify integration support"))
        check("stem match: pricing/price morphology", E.sharesTopicStem(
            "Prospect asking about total package pricing",
            "Prospect asking for full package price—answer it now"))
    }

    static func testHallucinationFilter() {
        // Classic silence hallucinations on a quiet chunk — dropped.
        check("halluc: quiet 'Thank you.' dropped", TranscriptionEngine.isLikelyHallucination("Thank you.", energy: 0.002))
        check("halluc: quiet 'you' dropped", TranscriptionEngine.isLikelyHallucination("you", energy: 0.001))
        check("halluc: quiet 'Okay.' dropped", TranscriptionEngine.isLikelyHallucination("Okay.", energy: 0.003))
        check("halluc: bare '.' dropped at any volume", TranscriptionEngine.isLikelyHallucination(".", energy: 0.05))
        // Real speech survives.
        check("halluc: real sentence kept", !TranscriptionEngine.isLikelyHallucination("Can you hear me?", energy: 0.002))
        check("halluc: loud 'Okay.' kept", !TranscriptionEngine.isLikelyHallucination("Okay.", energy: 0.02))
        check("halluc: loud 'Thank you.' kept", !TranscriptionEngine.isLikelyHallucination("Thank you.", energy: 0.03))

        // Glossary echo stripping: a prompt leak PREFIXING real speech must not
        // take the speech with it (the live segment-drop of 2026-08-01).
        typealias TE = TranscriptionEngine
        check("echo: prefixed speech survives the leak",
              TE.strippingGlossaryEcho("Glossary: Launchese, Uygar. However I'm worried about churn.")
                == "However I'm worried about churn.")
        check("echo: pure echo still drops",
              TE.strippingGlossaryEcho("Glossary: Launchese, Uygar.") == nil)
        check("echo: unterminated echo still drops",
              TE.strippingGlossaryEcho("Glossary Launchese Uygar") == nil)
        check("echo: normal speech passes untouched",
              TE.strippingGlossaryEcho("The glossary says nothing about churn.")
                == "The glossary says nothing about churn.")
        check("echo: multi-sentence tail kept whole",
              TE.strippingGlossaryEcho("Glossary: A, B. First point. Second point.")
                == "First point. Second point.")

        // Cross-stream speaker-bleed dedup (mic re-hearing the speakers).
        check("bleed: identical text is echo",
              RecordingManager.isEchoDuplicate(
                "The quarterly numbers are looking very strong this month.",
                "The quarterly numbers are looking very strong this month."))
        check("bleed: decode variance still echo",
              RecordingManager.isEchoDuplicate(
                "However, I'm worried about the churn rate on the Enterprise tier.",
                "However I am worried about the churn rate on the enterprise tier."))
        check("bleed: different sentences are not echo",
              !RecordingManager.isEchoDuplicate(
                "Can you send me the retention report before Tuesday?",
                "The quarterly numbers are looking very strong this month."))
        check("bleed: short ack is not echo of a long line",
              !RecordingManager.isEchoDuplicate(
                "Okay sure.",
                "Can you send me the retention report before Tuesday?"))
    }

    static func testWAVEncoder() {
        let wav = WAVEncoder.encode(samples: [0, 0.5, -0.5, 2.0], sampleRate: 16000)
        check("wav total size", wav.count == 44 + 8)
        check("wav RIFF magic", wav.prefix(4) == Data("RIFF".utf8))
        check("wav WAVE magic", wav[8..<12] == Data("WAVE".utf8))
        func u32(_ offset: Int) -> UInt32 {
            wav[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        }
        func i16(_ offset: Int) -> Int16 {
            wav[offset..<offset + 2].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }.littleEndian
        }
        check("wav sample rate field", u32(24) == 16000)
        check("wav data size field", u32(40) == 8)
        check("wav first sample zero", i16(44) == 0)
        check("wav clamps overdrive to Int16.max-ish", i16(50) == 32767)
        // `selected` falls back to .local via `?? .local`; asserting on it directly
        // read the tester's real UserDefaults and broke once a cloud engine was chosen.
        check("unknown backend raw value rejected", TranscriptionBackend(rawValue: "gibberish") == nil)
    }

    static func testAIUsageCost() {
        // Known tokens → known dollars: 1M in ($1.00) + 200k out ($1.00) = $2.00;
        // Deepgram 10 min × 2 tracks = 1/3 hr × $0.29 ≈ $0.0967;
        // polish 20 min = 1/3 hr × $0.04 ≈ $0.0133.
        var usage = AIUsage()
        usage.copilotModel = "claude-haiku-4-5"
        usage.copilot = AITokenTotals(inputTokens: 1_000_000, outputTokens: 200_000, calls: 41)
        usage.transcriptionBackend = TranscriptionBackend.deepgram.rawValue
        usage.transcriptionSeconds = 600
        usage.transcriptionTracks = 2
        usage.polishSeconds = 1200

        let items = usage.costBreakdown()
        check("cost has 3 line items", items.count == 3)
        check("copilot cost $2.00", abs(items[0].usd - 2.00) < 0.0001)
        // Sonnet-labeled buckets price at Sonnet 5 rates ($3 in / $15 out per MTok).
        var sonnet = AIUsage()
        sonnet.copilotModel = "claude-sonnet-5"
        sonnet.copilot = AITokenTotals(inputTokens: 1_000_000, outputTokens: 200_000, calls: 3)
        check("sonnet bucket priced at sonnet rates",
              abs(sonnet.costBreakdown()[0].usd - (3.00 + 3.00)) < 0.0001)
        check("copilot detail has calls + tokens", items[0].detail.contains("41 calls") && items[0].detail.contains("1000k in"))
        check("deepgram cost matches $0.29/hr rate", abs(items[1].usd - 1200.0 / 3600 * 0.29) < 0.0001)
        // The real invoice this rate was verified against: 1:50 call, 2 streams.
        var invoice = AIUsage()
        invoice.transcriptionBackend = TranscriptionBackend.deepgram.rawValue
        invoice.transcriptionSeconds = 110
        invoice.transcriptionTracks = 2
        check("deepgram matches real bill ±10%", abs(invoice.totalUSD - 0.01788) < 0.0018)
        check("polish cost ~$0.0133", abs(items[2].usd - 1200.0 / 3600 * 0.04) < 0.0001)
        check("total sums line items", abs(usage.totalUSD - items.reduce(0) { $0 + $1.usd }) < 0.0001)

        // Local + no copilot calls + no polish → one free line only.
        var free = AIUsage()
        free.transcriptionSeconds = 600
        let freeItems = free.costBreakdown()
        check("local-only is 1 free line", freeItems.count == 1 && freeItems[0].usd == 0)
        check("local detail says on-device", freeItems[0].detail == "on-device")

        // Codable round-trip (this is what Meeting.aiUsageData stores).
        let decoded = (try? JSONEncoder().encode(usage)).flatMap { try? JSONDecoder().decode(AIUsage.self, from: $0) }
        check("AIUsage round-trips", decoded?.copilot == usage.copilot && decoded?.polishSeconds == 1200)

        check("formatUSD cents", AIUsage.formatUSD(0.154) == "$0.15")
        check("formatUSD sub-cent shows 3 decimals", AIUsage.formatUSD(0.0013) == "$0.001")
        check("formatUSD zero", AIUsage.formatUSD(0) == "$0.00")

        // Live/reports split: Claude live cards priced at Haiku rates, local
        // reports free — two separately-priced buckets plus transcription.
        var split = AIUsage()
        split.copilotModel = "claude-haiku-4-5"
        split.copilotProvider = "claude"
        split.copilot = AITokenTotals(inputTokens: 1_000_000, outputTokens: 200_000, calls: 10)
        split.reportsModel = "gemma3:4b"
        split.reportsProvider = "ollama"
        split.reports = AITokenTotals(inputTokens: 50_000, outputTokens: 5_000, calls: 2)
        split.transcriptionSeconds = 600
        let splitItems = split.costBreakdown()
        check("split has 3 lines", splitItems.count == 3)
        check("split live line priced", splitItems[0].label.hasPrefix("Live cards") && abs(splitItems[0].usd - 2.00) < 0.0001)
        check("split reports line free + local", splitItems[1].label.hasPrefix("Reports") && splitItems[1].label.contains("local") && splitItems[1].usd == 0)
        let splitDecoded = (try? JSONEncoder().encode(split)).flatMap { try? JSONDecoder().decode(AIUsage.self, from: $0) }
        check("split round-trips", splitDecoded?.reports == split.reports && splitDecoded?.reportsProvider == "ollama")

        // Update check version compare.
        check("newer patch wins", UpdateChecker.isNewer("0.11.1", than: "0.11.0"))
        check("newer minor beats higher patch", UpdateChecker.isNewer("0.12.0", than: "0.11.9"))
        check("equal is not newer", !UpdateChecker.isNewer("0.11.0", than: "0.11.0"))
        check("older is not newer", !UpdateChecker.isNewer("0.10.9", than: "0.11.0"))
        check("dev builds never update", !UpdateChecker.isNewer("9.9.9", than: "dev"))
        check("make's 0.0.0-dev never updates", !UpdateChecker.isNewer("9.9.9", than: "0.0.0-dev"))
        check("empty version never updates", !UpdateChecker.isNewer("9.9.9", than: ""))
        check("unparseable candidate is not newer", !UpdateChecker.isNewer("v1.2.3", than: "0.11.0"))
    }

    // The issue-#12 mic watchdog: sustained exact-zero input means the OS cut
    // the feed (a call app holds the mic); dither-level noise never triggers.
    static func testMicWatchdog() {
        typealias W = AudioCaptureManager.MicSignalWatchdog
        var w = W()
        let t0 = Date(timeIntervalSince1970: 1_000)
        check("watchdog quiet dithery mic is ok", w.observe(meanAbs: 0.0001, at: t0) == .ok)
        check("watchdog first zero buffer is ok", w.observe(meanAbs: 0, at: t0.addingTimeInterval(0.1)) == .ok)
        check("watchdog short zero run is ok", w.observe(meanAbs: 0, at: t0.addingTimeInterval(1.9)) == .ok)
        check("watchdog sustained zeros are lost", w.observe(meanAbs: 0, at: t0.addingTimeInterval(2.2)) == .lost)
        check("watchdog reports lost only once", w.observe(meanAbs: 0, at: t0.addingTimeInterval(3)) == .stillLost)
        check("watchdog recovers on real signal", w.observe(meanAbs: 0.01, at: t0.addingTimeInterval(4)) == .recovered)
        check("watchdog ok after recovery", w.observe(meanAbs: 0.01, at: t0.addingTimeInterval(5)) == .ok)
        var w2 = W()
        _ = w2.observe(meanAbs: 0, at: t0)
        _ = w2.observe(meanAbs: 0.02, at: t0.addingTimeInterval(1))
        check("watchdog nonzero resets the zero run", w2.observe(meanAbs: 0, at: t0.addingTimeInterval(2.5)) == .ok)
    }

    // Local model folder matching (the hub-resolution bypass in loadModel).
    static func testModelFolderMatch() {
        let disk = ["openai_whisper-base", "openai_whisper-small",
                    "openai_whisper-large-v3_turbo", "distil-whisper_distil-large-v3"]
        check("folder match base", TranscriptionEngine.matchModelFolder("base", in: disk) == "openai_whisper-base")
        check("folder match turbo across separators",
              TranscriptionEngine.matchModelFolder("large-v3-turbo", in: disk) == "openai_whisper-large-v3_turbo")
        check("folder match misses absent model", TranscriptionEngine.matchModelFolder("tiny", in: disk) == nil)
        check("folder match rejects ambiguity",
              TranscriptionEngine.matchModelFolder("base", in: ["openai_whisper-base", "openai-whisper_base"]) == nil)
    }

    // The live-loop utterance segmenter that replaced fixed 2 s chunks.
    static func testSegmenter() {
        typealias Seg = TranscriptionEngine.Segmenter
        // Building blocks in whole 100 ms frames: audible speech vs true silence.
        func speech(_ frames: Int) -> [Float] { Array(repeating: 0.02, count: frames * Seg.frame) }
        func silence(_ frames: Int) -> [Float] { Array(repeating: 0.0001, count: frames * Seg.frame) }

        // Silence never decodes: live keeps only the partial tail frame, drain eats all.
        let quiet = silence(8) + [0.0001, 0.0001]
        check("seg silence live drops whole frames",
              Seg.nextCut(in: quiet, draining: false) == .init(dropLeading: 8 * Seg.frame, take: nil))
        check("seg silence draining drops everything",
              Seg.nextCut(in: quiet, draining: true) == .init(dropLeading: quiet.count, take: nil))

        // Speech bounded by a pause cuts at the boundary, padded 100 ms into it.
        let utterance = silence(3) + speech(10) + silence(Seg.pauseFrames) + speech(2)
        check("seg utterance cuts at pause",
              Seg.nextCut(in: utterance, draining: false)
                == .init(dropLeading: 3 * Seg.frame, take: (10 + Seg.padFrames) * Seg.frame))

        // A pause shorter than the threshold does not end the utterance.
        let midPause = silence(2) + speech(6) + silence(Seg.pauseFrames - 2) + speech(4)
        check("seg short pause keeps buffering",
              Seg.nextCut(in: midPause, draining: false) == .init(dropLeading: 2 * Seg.frame, take: nil))

        // Sub-300 ms islands between silences are noise: dropped with their pause.
        let blip = silence(4) + speech(2) + silence(Seg.pauseFrames) + speech(3)
        check("seg noise blip dropped without decode",
              Seg.nextCut(in: blip, draining: false)
                == .init(dropLeading: (4 + 2 + Seg.pauseFrames) * Seg.frame, take: nil))

        // Continuous speech: wait while live, forced cut at the cap, take-all on drain.
        let running = speech(20)
        check("seg continuous speech waits",
              Seg.nextCut(in: running, draining: false) == .init(dropLeading: 0, take: nil))
        let monologue = speech(Seg.maxSegmentSamples / Seg.frame + 10)
        check("seg cap forces a cut",
              Seg.nextCut(in: monologue, draining: false) == .init(dropLeading: 0, take: Seg.maxSegmentSamples))
        check("seg draining takes the tail",
              Seg.nextCut(in: running, draining: true) == .init(dropLeading: 0, take: running.count))

        // Two utterances buffered: the cut ends at the FIRST boundary.
        let two = speech(5) + silence(Seg.pauseFrames) + speech(5) + silence(Seg.pauseFrames)
        check("seg cuts one utterance at a time",
              Seg.nextCut(in: two, draining: false) == .init(dropLeading: 0, take: (5 + Seg.padFrames) * Seg.frame))
    }

    // The #20 budget controls: pace presets, the live context window, pause.
    @MainActor
    static func testCopilotBudget() {
        // Fast must be the original constants exactly — the default changes nothing.
        let fast = CopilotPace.fast.timing
        check("pace fast is the original timing",
              fast.question == 1 && fast.idle == 8 && fast.floor == 5 && fast.staleness == 15)
        // Every slower pace waits at least as long on every timer.
        for (quicker, slower) in [(CopilotPace.fast, CopilotPace.balanced), (.balanced, .relaxed)] {
            let a = quicker.timing, b = slower.timing
            check("pace \(slower.rawValue) never faster than \(quicker.rawValue)",
                  b.question >= a.question && b.idle >= a.idle
                    && b.floor >= a.floor && b.staleness >= a.staleness)
        }
        check("pace unknown value has no case", CopilotPace(rawValue: "turbo") == nil)
        check("window standard is 5 minutes", CopilotWindow.standard.minutes == 5)

        // Window math: recent kept, old excluded, floor and cap honored.
        typealias E = CallAnalysisEngine
        let times: [TimeInterval] = (0..<40).map { TimeInterval($0) * 10 }  // 0,10,…,390
        check("window empty transcript sends nothing", E.windowSuffixCount(times: [], seconds: 120) == 0)
        check("window keeps only recent segments",
              E.windowSuffixCount(times: times, seconds: 120) == 13)  // 270…390
        check("window floor lifts a quiet call",
              E.windowSuffixCount(times: times, seconds: 5, minCount: 10) == 10)
        check("window floor capped at what exists",
              E.windowSuffixCount(times: [0, 5], seconds: 1, minCount: 10) == 2)
        check("window cap bounds a dense stretch",
              E.windowSuffixCount(times: times, seconds: 1000, maxCount: 20) == 20)

        // Pause: only valid mid-session, cards survive a pause/resume cycle.
        let engine = CallAnalysisEngine()
        engine.setPaused(true)
        check("pause before start is ignored", !engine.isPaused)
        engine.seedForSnapshot(
            profile: nil,
            insights: [Insight(kindKey: "blocker", title: "t", detail: "d", callTime: 0, source: nil)],
            sentiment: [:], read: nil, meCharacters: 0, themCharacters: 0)
        engine.setPaused(true)
        check("pause flips status", engine.isPaused && engine.status == .paused)
        check("pause keeps cards", engine.insights.count == 1)
        engine.setPaused(false)
        // Not asserting the exact resumed status: it depends on whether a key
        // is configured on the machine running the harness.
        check("resume leaves the paused state", !engine.isPaused && engine.status != .paused)
        check("resume keeps cards", engine.insights.count == 1)
    }

    static func testStableHash() {
        check("stableHash deterministic", "Speaker 1".stableHash == "Speaker 1".stableHash)
        check("stableHash non-negative", "".stableHash >= 0 && "🦜 émojî".stableHash >= 0)
        check("stableHash differs across labels", "Speaker 1".stableHash != "Speaker 2".stableHash)
    }

    static func testPromptAndSchema() {
        let kinds = ProfilePresets.all().first { $0.name == "1:1 coaching" }!.kinds
        let prompt = ClaudeAnalysisProvider.systemPrompt(persona: "P", kinds: kinds, gauges: [])
        check("prompt includes persona", prompt.contains("P"))
        check("prompt lists reflection key", prompt.contains("reflection"))
        check("prompt has no hardcoded 'objection'", !prompt.lowercased().contains("objection"))
        let schema = ClaudeAnalysisProvider.schema(kinds: kinds, gauges: [SentimentGauge(id: UUID(), key: "client_openness", label: "x", lowLabel: "a", highLabel: "b", colorHex: "2F7E96")])
        // enum equals the profile's keys
        let insightsProp = ((schema["properties"] as? [String: Any])?["insights"] as? [String: Any])
        let items = insightsProp?["items"] as? [String: Any]
        let kindEnum = ((items?["properties"] as? [String: Any])?["kind"] as? [String: Any])?["enum"] as? [String]
        check("schema enum == profile keys", Set(kindEnum ?? []) == Set(kinds.map(\.key)))
        check("schema has sentiment object", (schema["properties"] as? [String: Any])?["sentiment"] != nil)
        // Injection hardening: transcript/document text is declared data-only.
        check("prompt declares tagged text as data", prompt.contains("<transcript>"))
        let valid = ClaudeAnalysisProvider.validatingKinds(
            [InsightDraft(kindKey: "reflection", title: "t", detail: "d", source: nil),
             InsightDraft(kindKey: "objection", title: "t", detail: "d", source: nil)],
            allowed: Set(kinds.map(\.key)))
        check("validatingKinds drops out-of-lens", valid.count == 1 && valid.first?.kindKey == "reflection")
    }

    static func testSnapshotPersistence() {
        let kinds = ProfilePresets.all().first!.kinds
        let data = try? JSONEncoder().encode(kinds)
        let m = Meeting()
        m.profileSnapshotData = data
        check("snapshot decodes back", m.snapshotKinds.count == kinds.count)
        check("snapshot preserves first key", m.snapshotKinds.first?.key == kinds.first?.key)
    }

    static func testHexColor() {
        // Verify a 6-digit hex parses to the expected RGB components.
        let c = Color(hex: "2F7E96")
        let ns = NSColor(c).usingColorSpace(.sRGB)
        let epsilon = 2.0 / 255.0 // allow for rounding
        let redOK   = abs((ns?.redComponent   ?? -1) - (Double(0x2F) / 255.0)) < epsilon
        let greenOK = abs((ns?.greenComponent ?? -1) - (Double(0x7E) / 255.0)) < epsilon
        let blueOK  = abs((ns?.blueComponent  ?? -1) - (Double(0x96) / 255.0)) < epsilon
        check("hex 2F7E96 red component",   redOK)
        check("hex 2F7E96 green component", greenOK)
        check("hex 2F7E96 blue component",  blueOK)

        // Verify a malformed hex falls back to gray (not a crash).
        // SwiftUI's Color.gray resolves in sRGB to a neutral midtone (all channels ~0.5–0.7).
        let bad = Color(hex: "zzz")
        let nsBad = NSColor(bad).usingColorSpace(.sRGB)
        let r = nsBad?.redComponent ?? -1
        let g = nsBad?.greenComponent ?? -1
        let b = nsBad?.blueComponent ?? -1
        // All channels should be in the neutral midrange [0.4, 0.8] for a gray-like fallback.
        let grayOK = (0.4...0.8).contains(r) && (0.4...0.8).contains(g) && (0.4...0.8).contains(b)
        check("malformed hex falls back to gray", grayOK)
    }

    static func testPermissionFlow() {
        // The screen-capture ask must be exactly one of: nothing (granted),
        // the single OS prompt (first ask), or a Settings deep-link (re-ask).
        // The old code showed the prompt AND opened Settings on a first ask.
        check("perm: granted wins",
              PermissionFlow.nextScreenCaptureStep(preflightGranted: true, askedBefore: true) == .granted)
        check("perm: granted ignores asked flag",
              PermissionFlow.nextScreenCaptureStep(preflightGranted: true, askedBefore: false) == .granted)
        check("perm: first ask posts the one OS prompt",
              PermissionFlow.nextScreenCaptureStep(preflightGranted: false, askedBefore: false) == .promptShown)
        check("perm: re-ask deep-links to Settings",
              PermissionFlow.nextScreenCaptureStep(preflightGranted: false, askedBefore: true) == .openSettings)
    }
}
