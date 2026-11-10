import AVFoundation
import Combine
import EventKit
import Foundation
import Speech
import UserNotifications
import WhisperKit

// MARK: - Errors

enum RecorderError: LocalizedError {
    case couldNotStart
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .couldNotStart: return "The recorder could not start."
        case .permissionDenied: return "Microphone access is off. Turn it on in Settings to record."
        }
    }
}

enum TranscriptionError: LocalizedError {
    case appleUnavailable
    case appleNotAuthorized
    case noEngineAvailable

    var errorDescription: String? {
        switch self {
        case .appleUnavailable: return "On-device speech recognition is not available on this phone right now."
        case .appleNotAuthorized: return "Speech recognition permission is off."
        case .noEngineAvailable: return "No transcription engine is available. Download the Whisper model in Settings, or allow speech recognition."
        }
    }
}

// MARK: - Microphone permission

func requestMicrophonePermission() async -> Bool {
    await withCheckedContinuation { continuation in
        AVAudioApplication.requestRecordPermission { granted in
            continuation.resume(returning: granted)
        }
    }
}

// MARK: - Audio recorder (Record + Journal modes)

/// Records to a single .m4a file with AVAudioRecorder. Keeps recording in
/// the background (UIBackgroundModes audio) and pauses gracefully on phone
/// calls, resuming when the call ends.
@MainActor
final class AudioRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var startDate: Date?
    private var accumulatedPause: TimeInterval = 0
    private var pauseStart: Date?
    private var cancellables = Set<AnyCancellable>()
    private var interruptionObserver: NSObjectProtocol?

    func start(to url: URL) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let newRecorder = try AVAudioRecorder(url: url, settings: settings)
        newRecorder.isMeteringEnabled = true
        guard newRecorder.record() else { throw RecorderError.couldNotStart }
        recorder = newRecorder
        fileURL = url
        startDate = Date()
        accumulatedPause = 0
        pauseStart = nil
        isRecording = true
        isPaused = false
        Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
            .store(in: &cancellables)
        registerInterruptionObserver()
    }

    func stop() -> (url: URL, duration: TimeInterval)? {
        guard let recorder, let url = fileURL else { return nil }
        recorder.stop()
        cancellables.removeAll()
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let duration = elapsed
        self.recorder = nil
        fileURL = nil
        isRecording = false
        isPaused = false
        return (url, duration)
    }

    private func tick() {
        guard let recorder, let startDate else { return }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        level = max(0, min(1, (power + 60) / 60))
        elapsed = Date().timeIntervalSince(startDate) - accumulatedPause
    }

    private func registerInterruptionObserver() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                self?.handleInterruption(note)
            }
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            if isRecording, !isPaused {
                recorder?.pause()
                pauseStart = Date()
                isPaused = true
            }
        case .ended:
            if isPaused,
               let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt,
               AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) {
                if let pauseStart {
                    accumulatedPause += Date().timeIntervalSince(pauseStart)
                }
                pauseStart = nil
                isPaused = false
                recorder?.record()
            }
        @unknown default:
            break
        }
    }
}

// MARK: - Audio player (recording playback)

@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var cancellables = Set<AnyCancellable>()

    func load(url: URL) {
        stop()
        guard let newPlayer = try? AVAudioPlayer(contentsOf: url) else { return }
        player = newPlayer
        duration = newPlayer.duration
        currentTime = 0
        newPlayer.prepareToPlay()
    }

    func play() {
        guard let player else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPlaying = true
        Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    self.cancellables.removeAll()
                }
            }
            .store(in: &cancellables)
    }

    func pause() {
        player?.pause()
        isPlaying = false
        cancellables.removeAll()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(time, player.duration))
        currentTime = player.currentTime
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        cancellables.removeAll()
    }
}

// MARK: - Live engine (Live mode)

/// Captures the mic through AVAudioEngine, saves a master .wav for playback,
/// and transcribes rolling 12-second chunks so the transcript, key points
/// and suggested questions update while the meeting is still happening.
@MainActor
final class LiveEngine: ObservableObject {
    @Published private(set) var isLive = false
    @Published private(set) var liveSegments: [TranscriptSegment] = []
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var isTranscribingChunk = false

    var onChunkError: ((Error) -> Void)?

    private let engine = AVAudioEngine()
    private var masterFile: AVAudioFile?
    private var masterURL: URL?
    private var pendingSamples: [Float] = []
    private var sampleRate: Double = 48_000
    private var chunkStartTime: TimeInterval = 0
    private var startDate: Date?
    private var cancellables = Set<AnyCancellable>()
    private var chunkTask: Task<Void, Never>?
    private let chunkDuration: TimeInterval = 12

    func start(masterURL: URL) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        sampleRate = format.sampleRate
        masterFile = try AVAudioFile(forWriting: masterURL, settings: format.settings)
        self.masterURL = masterURL
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handleTap(buffer: buffer)
        }
        engine.prepare()
        try engine.start()
        startDate = Date()
        chunkStartTime = 0
        pendingSamples = []
        liveSegments = []
        isLive = true
        Timer.publish(every: 0.25, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, let startDate else { return }
                self.elapsed = Date().timeIntervalSince(startDate)
                if self.elapsed - self.chunkStartTime >= self.chunkDuration {
                    self.flushChunk()
                }
            }
            .store(in: &cancellables)
    }

    func stop() -> (url: URL, duration: TimeInterval)? {
        flushChunk()
        chunkTask?.cancel()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        cancellables.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isLive = false
        guard let masterURL, let startDate else { return nil }
        return (masterURL, Date().timeIntervalSince(startDate))
    }

    private func handleTap(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        // Write to the master file synchronously on the tap thread (the
        // standard pattern for AVAudioFile), then hop only the copied
        // mono samples to the main actor for chunking.
        var mono = [Float](repeating: 0, count: frames)
        if channels >= 2 {
            let left = channelData[0]
            let right = channelData[1]
            for i in 0..<frames {
                mono[i] = (left[i] + right[i]) * 0.5
            }
        } else {
            let single = channelData[0]
            for i in 0..<frames {
                mono[i] = single[i]
            }
        }
        try? masterFile?.write(from: buffer)
        let samples = mono
        Task { @MainActor in
            self.pendingSamples.append(contentsOf: samples)
        }
    }

    private func flushChunk() {
        guard isLive, !pendingSamples.isEmpty else { return }
        let samples = pendingSamples
        pendingSamples = []
        let startTime = chunkStartTime
        chunkStartTime = elapsed
        isTranscribingChunk = true
        chunkTask = Task { @MainActor in
            defer { self.isTranscribingChunk = false }
            do {
                let url = try Self.writeWAV(samples: samples, sampleRate: self.sampleRate)
                defer { try? FileManager.default.removeItem(at: url) }
                let segments = try await TranscriptionService.shared.transcribeFile(url: url)
                let shifted = segments.map { segment -> TranscriptSegment in
                    var copy = segment
                    copy.start += startTime
                    copy.end += startTime
                    return copy
                }
                self.liveSegments.append(contentsOf: shifted)
                self.liveSegments = SpeakerTurns.assignSpeakers(to: self.liveSegments)
            } catch {
                if Task.isCancelled { return }
                self.onChunkError?(error)
            }
        }
    }

    private static func writeWAV(samples: [Float], sampleRate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw RecorderError.couldNotStart
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw RecorderError.couldNotStart
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData {
            for (index, sample) in samples.enumerated() {
                channel[0][index] = sample
            }
        }
        try file.write(from: buffer)
        return url
    }
}

// MARK: - Speaker turn detection

/// Best-effort on-device speaker labels: a pause longer than the threshold
/// between segments is treated as a turn change. Alternates between two
/// speakers; the user can rename or reassign speakers by hand in the UI.
/// This is the known weak part of on-device diarization — it is labelled
/// as a best guess wherever it appears.
enum SpeakerTurns {
    static func assignSpeakers(to segments: [TranscriptSegment], gapThreshold: Double = 1.2) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var current = 0
        var previousEnd: Double?
        for segment in segments {
            if let previousEnd, segment.start - previousEnd > gapThreshold {
                current = (current + 1) % 2
            }
            var copy = segment
            copy.speaker = current
            out.append(copy)
            previousEnd = segment.end
        }
        return out
    }
}

// MARK: - Transcription (WhisperKit + Apple fallback)

enum WhisperModel: String, CaseIterable, Codable {
    case base = "base"
    case small = "small"

    var displayName: String {
        switch self {
        case .base: return "Base (~150 MB)"
        case .small: return "Small (~500 MB)"
        }
    }
}

enum WhisperState: Equatable {
    case notDownloaded
    case downloading
    case ready
    case appleFallback
    case failed(String)
}

/// Transcribes audio files on-device. Primary engine is Whisper via
/// WhisperKit (Core ML; the model downloads from Hugging Face on first
/// launch). If Whisper is unavailable (no model yet, no network, load
/// failure) it falls back to Apple's on-device Speech framework, which
/// needs no download. `shared` exists so the Live engine can transcribe
/// chunks without its own service instance.
@MainActor
final class TranscriptionService: ObservableObject {
    static let shared = TranscriptionService()

    @Published private(set) var whisperState: WhisperState = .notDownloaded
    @Published var selectedModel: WhisperModel = .base {
        didSet {
            UserDefaults.standard.set(selectedModel.rawValue, forKey: "dscribe.whisperModel")
            pipe = nil
            if whisperState == .ready || whisperState == .failed("") {
                whisperState = .notDownloaded
            }
        }
    }
    @Published var preferApple: Bool = false {
        didSet { UserDefaults.standard.set(preferApple, forKey: "dscribe.preferApple") }
    }

    private var pipe: WhisperKit?

    init() {
        if let saved = UserDefaults.standard.string(forKey: "dscribe.whisperModel"),
           let model = WhisperModel(rawValue: saved) {
            selectedModel = model
        }
        preferApple = UserDefaults.standard.bool(forKey: "dscribe.preferApple")
    }

    /// Starts the Whisper model download in the background (base model on
    /// first launch). Safe to call repeatedly; no-ops once ready.
    func ensureReady() async {
        if preferApple {
            whisperState = .appleFallback
            return
        }
        if pipe != nil {
            whisperState = .ready
            return
        }
        whisperState = .downloading
        do {
            let newPipe = try await WhisperKit(WhisperKitConfig(model: selectedModel.rawValue))
            pipe = newPipe
            whisperState = .ready
        } catch {
            whisperState = .failed(error.localizedDescription)
        }
    }

    /// Transcribe a file. Uses Whisper when ready, otherwise Apple's
    /// on-device recognizer. Throws only if both engines fail.
    func transcribeFile(url: URL) async throws -> [TranscriptSegment] {
        await ensureReady()
        if !preferApple, let pipe {
            do {
                let duration = audioDuration(of: url)
                let results: [TranscriptionSegment]
                if duration > 300 {
                    // Long recordings: bounded-memory incremental loading.
                    let options = AudioInputOptions(audioLoadingMode: .incremental)
                    results = try await pipe.transcribe(audioPath: url.path, audioInputOptions: options)
                } else {
                    results = try await pipe.transcribe(audioPath: url.path)
                }
                var segments = results.map {
                    TranscriptSegment(text: $0.text, start: Double($0.start), end: Double($0.end))
                }
                segments = SpeakerTurns.assignSpeakers(to: segments)
                return segments
            } catch {
                // Whisper failed mid-flight (e.g. model evicted) — fall through.
            }
        }
        return try await appleTranscribe(url: url)
    }

    private func appleTranscribe(url: URL) async throws -> [TranscriptSegment] {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw TranscriptionError.appleUnavailable
        }
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard status == .authorized else { throw TranscriptionError.appleNotAuthorized }
        return try await withCheckedThrowingContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = false
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if !finished {
                        finished = true
                        continuation.resume(throwing: error)
                    }
                    return
                }
                if let result, result.isFinal, !finished {
                    finished = true
                    let segments = result.bestTranscription.segments.map {
                        TranscriptSegment(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration)
                    }
                    continuation.resume(returning: SpeakerTurns.assignSpeakers(to: segments))
                }
            }
        }
    }

    private func audioDuration(of url: URL) -> TimeInterval {
        let asset = AVURLAsset(url: url)
        return CMTimeGetSeconds(asset.duration)
    }
}

// MARK: - Summary engine (extractive, v1)

/// V1 summaries are extractive and template-based: they pick and sort
/// sentences the user actually said. No LLM runs on the phone yet.
/// The engine is a separate type with a single entry point so a future
/// LLM engine (Playground model / ProDesk) can replace it without
/// touching the UI or the data model.
enum SummaryEngine {
    struct Sentence {
        let text: String
        let speaker: Int
        let start: Double
    }

    static func sentences(from segments: [TranscriptSegment]) -> [Sentence] {
        var out: [Sentence] = []
        for segment in segments {
            for piece in splitSentences(segment.text) {
                out.append(Sentence(text: piece, speaker: segment.speaker, start: segment.start))
            }
        }
        return out
    }

    static func summarize(segments: [TranscriptSegment], speakerName: (Int) -> String) -> Summary {
        let sentences = sentences(from: segments)
        let keyPoints = keyPoints(from: sentences)
        let decisions = sentences
            .filter { isDecision($0.text) }
            .map { $0.text }
            .uniqued()
            .prefix(5)
        let actionItems = sentences
            .filter { isActionItem($0.text) }
            .map { ActionItem(text: $0.text, owner: speakerName($0.speaker)) }
            .prefix(8)
        let questions = sentences
            .filter { isQuestion($0.text) }
            .map { $0.text }
            .uniqued()
            .prefix(5)
        return Summary(
            keyPoints: keyPoints,
            decisions: Array(decisions),
            actionItems: Array(actionItems),
            openQuestions: Array(questions),
            generatedAt: Date(),
            engine: "on-device v1 (extractive)"
        )
    }

    static func keyPoints(from sentences: [Sentence], limit: Int = 5) -> [String] {
        guard !sentences.isEmpty else { return [] }
        let frequencies = wordFrequencies(in: sentences.map { $0.text }.joined(separator: " "))
        let scored = sentences.enumerated().map { (index, sentence) -> (Int, Sentence, Double) in
            let words = contentWords(in: sentence.text)
            guard words.count >= 4, !isQuestion(sentence.text) else { return (index, sentence, -1) }
            let score = words.reduce(0.0) { $0 + Double(frequencies[$1] ?? 1) } / sqrt(Double(words.count))
            return (index, sentence, score)
        }
        let top = scored
            .filter { $0.2 > 0 }
            .sorted { $0.2 > $1.2 }
            .prefix(limit)
            .sorted { $0.0 < $1.0 }
        var seen = Set<String>()
        var out: [String] = []
        for (_, sentence, _) in top where seen.insert(sentence.text).inserted {
            out.append(sentence.text)
        }
        // Very short transcripts: fall back to the first sentences.
        if out.isEmpty {
            out = sentences.prefix(limit).map { $0.text }
        }
        return out
    }

    static func contentWords(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 && !stopwords.contains($0) }
    }

    static func wordFrequencies(in text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for word in contentWords(in: text) {
            counts[word, default: 0] += 1
        }
        return counts
    }

    private static func splitSentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { out.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    private static func isDecision(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["decided", "decision", "agreed", "let's go with", "we'll go with", "going with",
                "final call", "settled on", "we chose"].contains { lower.contains($0) }
    }

    private static func isActionItem(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["will ", "need to", "should ", "have to", "going to", "let's ",
                "must ", "by tomorrow", "by friday", "by monday", "next week",
                "i'll ", "you'll ", "we'll "].contains { lower.contains($0) }
    }

    private static func isQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("?") { return true }
        let lower = trimmed.lowercased()
        return ["what ", "how ", "when ", "who ", "where ", "why ",
                "should we", "can we", "do we", "is there", "are we"].contains { lower.hasPrefix($0) }
    }

    private static let stopwords: Set<String> = [
        "that", "this", "with", "from", "have", "been", "were", "they", "them",
        "then", "than", "there", "here", "when", "what", "about", "into", "just",
        "like", "over", "also", "really", "actually", "going", "think", "know",
        "yeah", "okay", "right", "well", "mean", "kind", "sort", "thing",
        "things", "much", "more", "some", "very", "even", "still", "back",
        "after", "before", "because", "through", "between", "under", "while",
    ]
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}

// MARK: - Suggested questions (Live mode, template-based)

/// Rolling question suggestions for the Live tab. Template-based in v1:
/// keyword rules over the transcript so far. Labelled as such in the UI.
enum SuggestedQuestions {
    static func suggestions(for transcript: String, limit: Int = 3) -> [String] {
        let lower = transcript.lowercased()
        var out: [String] = []
        if lower.contains("budget") || lower.contains("cost") || lower.contains("price") {
            out.append("What is the budget for this?")
        }
        if lower.contains("deadline") || lower.contains("due") || lower.contains("timeline") || lower.contains("launch") {
            out.append("When is this due, and who owns the date?")
        }
        if lower.contains("problem") || lower.contains("issue") || lower.contains("blocked") || lower.contains("risk") {
            out.append("What would unblock this?")
        }
        if lower.contains("decid") || lower.contains("option") || lower.contains("choose") {
            out.append("Who makes the final call here?")
        }
        if lower.contains("next step") || lower.contains("follow up") || lower.contains("action") {
            out.append("What are the next steps, and who owns each one?")
        }
        if out.isEmpty {
            out = [
                "What is the most important thing to decide in this meeting?",
                "Is there anything that needs a follow-up after this?",
            ]
        }
        return Array(out.prefix(limit))
    }
}

// MARK: - Calendar (opt-in auto-start)

/// Calendar auto-start, v1 behavior (honest about iOS limits):
/// - If the app is open when a meeting starts, recording starts itself.
/// - Otherwise a local notification fires at the meeting start time so the
///   user can open Dscribe and tap Record.
/// Silent background auto-recording is not something iOS allows a normal
/// app to do, so v1 does not pretend otherwise.
@MainActor
final class CalendarService: ObservableObject {
    @Published var autoStartEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(autoStartEnabled, forKey: "dscribe.calendarAutoStart")
            if autoStartEnabled {
                requestAccess()
            }
        }
    }

    private let eventStore = EKEventStore()
    private var accessGranted = false

    init() {
        autoStartEnabled = UserDefaults.standard.bool(forKey: "dscribe.calendarAutoStart")
        if autoStartEnabled {
            requestAccess()
        }
    }

    func requestAccess() {
        eventStore.requestFullAccessToEvents { [weak self] granted, _ in
            Task { @MainActor in
                self?.accessGranted = granted
            }
        }
    }

    /// Next non-all-day event starting within the given window.
    func nextMeeting(within minutes: Double = 30) -> EKEvent? {
        guard accessGranted else { return nil }
        let now = Date()
        let predicate = eventStore.predicateForEvents(
            withStart: now,
            end: now.addingTimeInterval(minutes * 60),
            calendars: nil
        )
        return eventStore.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
            .first
    }

    func scheduleStartNotification(for event: EKEvent) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "Meeting starting"
        content.body = "“\(event.title)” is starting — open Dscribe to record."
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: event.startDate),
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: "dscribe-\(event.eventIdentifier)",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }
}
