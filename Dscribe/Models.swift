import Foundation

// MARK: - Modes

enum RecordingMode: String, Codable, CaseIterable {
    case record
    case live
    case journal

    var displayName: String {
        switch self {
        case .record: return "Recording"
        case .live: return "Live session"
        case .journal: return "Journal entry"
        }
    }
}

// MARK: - Transcript

/// One transcribed utterance. `speaker` is an index into the recording's
/// speakerNames map. Speaker labels are a best guess on-device (turn
/// detection on pauses) — the user can rename them by hand in the UI.
struct TranscriptSegment: Identifiable, Codable, Equatable {
    var id: UUID
    var text: String
    var start: Double
    var end: Double
    var speaker: Int

    init(id: UUID = UUID(), text: String, start: Double, end: Double, speaker: Int = 0) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

// MARK: - Summary

struct ActionItem: Identifiable, Codable, Equatable {
    var id: UUID
    var text: String
    var owner: String?
    var done: Bool

    init(id: UUID = UUID(), text: String, owner: String? = nil, done: Bool = false) {
        self.id = id
        self.text = text
        self.owner = owner
        self.done = done
    }
}

/// V1 summary. Produced on-device by the extractive SummaryEngine.
/// `engine` records which engine made it, so a future LLM engine can be
/// swapped in without changing the data model.
struct Summary: Codable, Equatable {
    var keyPoints: [String]
    var decisions: [String]
    var actionItems: [ActionItem]
    var openQuestions: [String]
    var generatedAt: Date
    var engine: String
}

// MARK: - Recording

struct Recording: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var mode: RecordingMode
    var createdAt: Date
    var duration: Double
    var audioFileName: String
    var segments: [TranscriptSegment]
    var speakerNames: [Int: String]
    var summary: Summary?
    var isTranscribed: Bool

    init(
        id: UUID = UUID(),
        title: String,
        mode: RecordingMode,
        createdAt: Date = Date(),
        duration: Double,
        audioFileName: String,
        segments: [TranscriptSegment] = [],
        speakerNames: [Int: String] = [:],
        summary: Summary? = nil,
        isTranscribed: Bool = false
    ) {
        self.id = id
        self.title = title
        self.mode = mode
        self.createdAt = createdAt
        self.duration = duration
        self.audioFileName = audioFileName
        self.segments = segments
        self.speakerNames = speakerNames
        self.summary = summary
        self.isTranscribed = isTranscribed
    }

    func speakerName(for index: Int) -> String {
        speakerNames[index] ?? "Speaker \(index + 1)"
    }

    var fullText: String {
        segments.map { $0.text }.joined(separator: " ")
    }
}

// MARK: - Store

/// Persists recordings metadata as JSON in Documents/Dscribe/library.json
/// and audio files in Documents/Dscribe/Recordings/. Nothing leaves the device.
@MainActor
final class RecordingStore: ObservableObject {
    @Published private(set) var recordings: [Recording] = []

    private let libraryURL: URL
    private let recordingsDir: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let base = docs.appendingPathComponent("Dscribe", isDirectory: true)
        recordingsDir = base.appendingPathComponent("Recordings", isDirectory: true)
        libraryURL = base.appendingPathComponent("library.json")
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: libraryURL),
              let decoded = try? JSONDecoder().decode([Recording].self, from: data) else {
            recordings = []
            return
        }
        recordings = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(recordings) else { return }
        try? data.write(to: libraryURL, options: .atomic)
    }

    func add(_ recording: Recording) {
        recordings.insert(recording, at: 0)
        save()
    }

    func update(_ recording: Recording) {
        guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        recordings[index] = recording
        save()
    }

    func delete(_ recording: Recording) {
        try? FileManager.default.removeItem(at: audioURL(for: recording))
        recordings.removeAll { $0.id == recording.id }
        save()
    }

    func audioURL(for recording: Recording) -> URL {
        recordingsDir.appendingPathComponent(recording.audioFileName)
    }

    func newAudioURL(fileExtension: String) -> URL {
        recordingsDir.appendingPathComponent(UUID().uuidString + "." + fileExtension)
    }

    func recordings(for mode: RecordingMode) -> [Recording] {
        recordings.filter { $0.mode == mode }
    }

    func search(_ query: String) -> [Recording] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return recordings }
        let lower = trimmed.lowercased()
        return recordings.filter { recording in
            recording.title.lowercased().contains(lower)
                || recording.fullText.lowercased().contains(lower)
        }
    }

    /// Total bytes of stored audio, for the Settings screen.
    var storageUsedBytes: Int64 {
        var total: Int64 = 0
        for recording in recordings {
            let url = audioURL(for: recording)
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 {
                total += size
            }
        }
        return total
    }
}

// MARK: - Journal insights

struct JournalReminder: Identifiable, Equatable {
    let id: String
    let text: String
    let entryDate: Date
    let entryID: UUID
}

/// Patterns across journal entries. All computed locally from the
/// transcripts the user already has — no network, no model call.
enum JournalInsights {
    private static let commitmentMarkers = [
        "i will", "i'll", "i need to", "i should", "i have to",
        "i must", "remember to", "don't forget", "tomorrow", "next week"
    ]

    /// Sentences where the user committed to doing something.
    static func commitments(from entries: [Recording]) -> [JournalReminder] {
        var out: [JournalReminder] = []
        for entry in entries {
            for (index, sentence) in SummaryEngine.sentences(from: entry.segments).enumerated() {
                let lower = sentence.text.lowercased()
                guard commitmentMarkers.contains(where: { lower.contains($0) }) else { continue }
                // Stable ID: entry + sentence position, so a reminder marked
                // done stays done across app launches.
                let id = "\(entry.id.uuidString)-\(index)"
                out.append(JournalReminder(id: id, text: sentence.text, entryDate: entry.createdAt, entryID: entry.id))
            }
        }
        return out
    }

    /// Most-mentioned content words across entries, for the "you keep
    /// talking about" pattern view.
    static func topics(from entries: [Recording], limit: Int = 8) -> [(word: String, count: Int)] {
        var counts: [String: Int] = [:]
        for entry in entries {
            for word in SummaryEngine.contentWords(in: entry.fullText) {
                counts[word, default: 0] += 1
            }
        }
        return counts
            .filter { $0.value > 1 }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (word: $0.key, count: $0.value) }
    }

    /// Consecutive days (ending today or yesterday) with at least one entry.
    static func streakDays(entries: [Recording]) -> Int {
        let calendar = Calendar.current
        let days = Set(entries.map { calendar.startOfDay(for: $0.createdAt) })
        var day = calendar.startOfDay(for: Date())
        if !days.contains(day) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day), days.contains(yesterday) else {
                return 0
            }
            day = yesterday
        }
        var streak = 0
        while days.contains(day) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }
}
