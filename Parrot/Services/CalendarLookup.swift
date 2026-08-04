import EventKit
import Foundation

/// Finds who a recorded call was with by matching the recording window against
/// the user's macOS Calendar (which carries Google/Exchange invites when those
/// accounts are added in System Settings → Internet Accounts).
///
/// Used post-call only: the cleaned-transcript prompt and the report address
/// the other side by their real name instead of "the other person". Calendar
/// access prompts once on first use; a denial (or no matching event) just
/// means the generic wording is used — never an error.
enum CalendarLookup {
    /// The other attendees' names for the event overlapping the recording, or
    /// the event's title when the invite carries no usable attendee names, or
    /// nil when there's no access / no overlapping event.
    static func counterpartName(around start: Date, duration: TimeInterval) async -> String? {
        let store = EKEventStore()
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        guard granted else { return nil }

        // Pad the window: calls routinely start a few minutes off the invite.
        let recordingEnd = start.addingTimeInterval(max(duration, 60))
        let predicate = store.predicateForEvents(
            withStart: start.addingTimeInterval(-20 * 60),
            end: recordingEnd.addingTimeInterval(20 * 60),
            calendars: nil
        )
        let events = store.events(matching: predicate).filter { !$0.isAllDay }
        guard let best = bestMatch(
            events: events.map { (start: $0.startDate ?? .distantPast,
                                  end: $0.endDate ?? .distantFuture) },
            recordingStart: start, recordingEnd: recordingEnd
        ) else { return nil }
        let event = events[best]

        // Everyone on the invite except the user; person-type participants
        // only (rooms and resource calendars also appear as attendees).
        let others = (event.attendees ?? [])
            .filter { !$0.isCurrentUser && $0.participantType == .person }
            .compactMap { $0.name?.trimmingCharacters(in: .whitespaces).nilIfEmpty }
            // Some invites surface the raw address as the name — skip those.
            .filter { !$0.contains("@") }
        if !others.isEmpty {
            return others.prefix(3).joined(separator: ", ")
        }
        return event.title?.trimmingCharacters(in: .whitespaces).nilIfEmpty
    }

    /// Index of the event overlapping the recording the most; nil if none
    /// overlap at all. Pure so --profile-test can drive it.
    static func bestMatch(
        events: [(start: Date, end: Date)], recordingStart: Date, recordingEnd: Date
    ) -> Int? {
        var bestIndex: Int?
        var bestOverlap: TimeInterval = 0
        for (index, event) in events.enumerated() {
            let overlap = min(event.end, recordingEnd).timeIntervalSince(
                max(event.start, recordingStart))
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestIndex = index
            }
        }
        return bestIndex
    }
}
