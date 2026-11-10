import EventKit
import SwiftUI

// MARK: - Helpers

func formatDuration(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

struct LevelMeter: View {
    var level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(4, geometry.size.width * CGFloat(level)))
            }
        }
        .frame(height: 6)
    }
}

struct RecordingIndicator: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .opacity(pulse ? 0.35 : 1.0)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }
            Text("Recording")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.red)
        }
    }
}

// MARK: - Record tab

struct RecordView: View {
    @EnvironmentObject var store: RecordingStore
    @EnvironmentObject var transcription: TranscriptionService
    @EnvironmentObject var calendar: CalendarService

    @StateObject private var recorder = AudioRecorder()
    @State private var searchText = ""
    @State private var showingConsent = false
    @State private var showingSettings = false
    @State private var showingMicDeniedAlert = false
    @State private var transcribeError: String?
    @State private var isTranscribing = false
    @State private var upcomingMeeting: EventKit.EKEvent?
    @State private var notifiedEventIDs = Set<String>()
    @AppStorage("dscribe.consentGiven") private var consentGiven = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 16) {
                        if recorder.isRecording {
                            RecordingIndicator()
                            Text(formatDuration(recorder.elapsed))
                                .font(.system(.largeTitle, design: .monospaced))
                            LevelMeter(level: recorder.level)
                                .padding(.horizontal)
                            if recorder.isPaused {
                                Text("Paused — phone call. Resumes automatically.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Tap to record a meeting, a class, or anything important.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        Button(action: recordButtonTapped) {
                            Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(.white)
                                .frame(width: 88, height: 88)
                                .background(recorder.isRecording ? Color.red : Color.accentColor, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")
                        if isTranscribing {
                            ProgressView("Transcribing on-device…")
                                .font(.footnote)
                        }
                        modelStatusRow
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                if let meeting = upcomingMeeting, !recorder.isRecording {
                    Section {
                        HStack {
                            Image(systemName: "calendar")
                            VStack(alignment: .leading) {
                                Text("“\(meeting.title)” starts \(meeting.startDate, style: .time)")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                Text("Auto-start is on — recording begins when it starts.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Recordings") {
                    let recordings = store.search(searchText)
                    if recordings.isEmpty {
                        ContentUnavailableView(
                            "No recordings yet",
                            systemImage: "mic",
                            description: Text("Your first recording will appear here, with its transcript and summary.")
                        )
                    } else {
                        ForEach(recordings) { recording in
                            NavigationLink(value: recording.id) {
                                RecordingRow(recording: recording)
                            }
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                store.delete(recordings[index])
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search recordings and transcripts")
            .navigationTitle("Record")
            .navigationDestination(for: UUID.self) { id in
                RecordingDetailView(recordingID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingConsent) {
                ConsentView(onConfirm: {
                    consentGiven = true
                    showingConsent = false
                    Task { await startRecording() }
                })
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .alert("Microphone access is off", isPresented: $showingMicDeniedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Turn on microphone access in Settings to record.")
            }
            .alert("Transcription failed", isPresented: .constant(transcribeError != nil)) {
                Button("OK", role: .cancel) { transcribeError = nil }
            } message: {
                Text(transcribeError ?? "")
            }
            .task {
                await transcription.ensureReady()
                checkUpcomingMeeting()
            }
            .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
                checkUpcomingMeeting()
            }
        }
    }

    @ViewBuilder
    private var modelStatusRow: some View {
        switch transcription.whisperState {
        case .downloading:
            Label("Downloading Whisper model…", systemImage: "arrow.down.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .failed:
            Label("Whisper model unavailable — using Apple on-device recognition.", systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .appleFallback:
            Label("Using Apple on-device recognition.", systemImage: "waveform")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .ready, .notDownloaded:
            EmptyView()
        }
    }

    private func recordButtonTapped() {
        if recorder.isRecording {
            finishRecording()
        } else if !consentGiven {
            showingConsent = true
        } else {
            Task { await startRecording() }
        }
    }

    private func startRecording() async {
        guard await requestMicrophonePermission() else {
            showingMicDeniedAlert = true
            return
        }
        do {
            try recorder.start(to: store.newAudioURL(fileExtension: "m4a"))
        } catch {
            transcribeError = error.localizedDescription
        }
    }

    private func finishRecording() {
        guard let result = recorder.stop() else { return }
        let recording = Recording(
            title: "Recording \(Date().formatted(date: .abbreviated, time: .shortened))",
            mode: .record,
            duration: result.duration,
            audioFileName: result.url.lastPathComponent
        )
        store.add(recording)
        transcribe(recording: recording, url: result.url)
    }

    private func transcribe(recording: Recording, url: URL) {
        isTranscribing = true
        Task {
            defer { isTranscribing = false }
            do {
                var updated = recording
                updated.segments = try await transcription.transcribeFile(url: url)
                updated.summary = SummaryEngine.summarize(segments: updated.segments) { updated.speakerName(for: $0) }
                updated.isTranscribed = true
                store.update(updated)
            } catch {
                transcribeError = error.localizedDescription
            }
        }
    }

    private func checkUpcomingMeeting() {
        guard calendar.autoStartEnabled else {
            upcomingMeeting = nil
            return
        }
        guard let meeting = calendar.nextMeeting(within: 30) else {
            upcomingMeeting = nil
            return
        }
        upcomingMeeting = meeting
        if !notifiedEventIDs.contains(meeting.eventIdentifier) {
            notifiedEventIDs.insert(meeting.eventIdentifier)
            calendar.scheduleStartNotification(for: meeting)
        }
        // Foreground auto-start: the meeting just started and we are open.
        if meeting.startDate <= Date(),
           Date().timeIntervalSince(meeting.startDate) < 60,
           !recorder.isRecording,
           consentGiven {
            Task { await startRecording() }
        }
    }
}

struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recording.title)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(formatDuration(recording.duration))
                Text("·")
                Text(recording.mode.displayName)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if recording.isTranscribed {
                Text(recording.summary?.keyPoints.first ?? recording.fullText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Label("Not transcribed yet", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Recording detail

struct RecordingDetailView: View {
    @EnvironmentObject var store: RecordingStore
    @EnvironmentObject var transcription: TranscriptionService

    let recordingID: UUID
    @StateObject private var player = AudioPlayer()
    @State private var renamingSpeaker: Int?
    @State private var newSpeakerName = ""
    @State private var showingDeleteConfirmation = false
    @State private var isTranscribing = false
    @State private var transcribeError: String?
    @Environment(\.dismiss) private var dismiss

    private var recording: Recording? {
        store.recordings.first { $0.id == recordingID }
    }

    var body: some View {
        Group {
            if let recording {
                detailContent(recording)
            } else {
                ContentUnavailableView("Recording deleted", systemImage: "trash")
            }
        }
        .navigationTitle("Recording")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detailContent(_ recording: Recording) -> some View {
        List {
            Section {
                HStack {
                    Button {
                        if player.isPlaying { player.pause() } else { player.play() }
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 44))
                    }
                    .buttonStyle(.plain)
                    VStack(alignment: .leading) {
                        Slider(value: Binding(
                            get: { player.currentTime },
                            set: { player.seek(to: $0) }
                        ), in: 0...max(player.duration, 0.01))
                        HStack {
                            Text(formatDuration(player.currentTime))
                            Spacer()
                            Text(formatDuration(player.duration))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Text("\(recording.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(formatDuration(recording.duration)) · \(recording.mode.displayName)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let summary = recording.summary {
                Section("Summary") {
                    if !summary.keyPoints.isEmpty {
                        SummaryGroup(title: "Key points", items: summary.keyPoints)
                    }
                    if !summary.decisions.isEmpty {
                        SummaryGroup(title: "Decisions", items: summary.decisions)
                    }
                    if !summary.actionItems.isEmpty {
                        Text("Action items")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        ForEach(summary.actionItems) { item in
                            HStack(alignment: .top) {
                                Button {
                                    toggleActionItem(item, in: recording)
                                } label: {
                                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(item.done ? .green : .secondary)
                                }
                                .buttonStyle(.plain)
                                VStack(alignment: .leading) {
                                    Text(item.text)
                                        .strikethrough(item.done)
                                    if let owner = item.owner {
                                        Text(owner)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    if !summary.openQuestions.isEmpty {
                        SummaryGroup(title: "Open questions", items: summary.openQuestions)
                    }
                    Text("Summary: \(summary.engine)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if recording.isTranscribed {
                Section("Summary") {
                    Text("No summary — the transcript was too short to summarize.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Transcript") {
                if recording.segments.isEmpty {
                    if isTranscribing {
                        ProgressView("Transcribing on-device…")
                    } else {
                        Text("No transcript yet.")
                            .foregroundStyle(.secondary)
                        Button("Transcribe now") {
                            transcribeNow(recording)
                        }
                    }
                } else {
                    Text("Speaker labels are a best guess — tap a name to fix it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(recording.segments) { segment in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Button {
                                    renamingSpeaker = segment.speaker
                                    newSpeakerName = recording.speakerName(for: segment.speaker)
                                } label: {
                                    Text(recording.speakerName(for: segment.speaker))
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                Text(formatDuration(segment.start))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(segment.text)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ShareLink(item: shareText(for: recording), subject: Text(recording.title)) {
                        Label("Share transcript", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Delete recording", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Rename speaker", isPresented: .constant(renamingSpeaker != nil)) {
            TextField("Speaker name", text: $newSpeakerName)
            Button("Save") {
                if let index = renamingSpeaker {
                    var updated = recording
                    let name = newSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        updated.speakerNames[index] = name
                        store.update(updated)
                    }
                }
                renamingSpeaker = nil
            }
            Button("Cancel", role: .cancel) { renamingSpeaker = nil }
        }
        .confirmationDialog("Delete this recording?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                store.delete(recording)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The audio and its transcript will be deleted from this phone.")
        }
        .alert("Transcription failed", isPresented: .constant(transcribeError != nil)) {
            Button("OK", role: .cancel) { transcribeError = nil }
        } message: {
            Text(transcribeError ?? "")
        }
        .onAppear {
            player.load(url: store.audioURL(for: recording))
        }
        .onDisappear {
            player.stop()
        }
    }

    private func toggleActionItem(_ item: ActionItem, in recording: Recording) {
        var updated = recording
        guard var summary = updated.summary,
              let index = summary.actionItems.firstIndex(where: { $0.id == item.id }) else { return }
        summary.actionItems[index].done.toggle()
        updated.summary = summary
        store.update(updated)
    }

    private func transcribeNow(_ recording: Recording) {
        isTranscribing = true
        Task {
            defer { isTranscribing = false }
            do {
                var updated = recording
                updated.segments = try await transcription.transcribeFile(url: store.audioURL(for: recording))
                updated.summary = SummaryEngine.summarize(segments: updated.segments) { updated.speakerName(for: $0) }
                updated.isTranscribed = true
                store.update(updated)
            } catch {
                transcribeError = error.localizedDescription
            }
        }
    }

    private func shareText(for recording: Recording) -> String {
        var text = "\(recording.title)\n\(recording.createdAt.formatted(date: .abbreviated, time: .shortened))\n\n"
        if let summary = recording.summary {
            text += "KEY POINTS\n" + summary.keyPoints.map { "• \($0)" }.joined(separator: "\n") + "\n\n"
        }
        text += "TRANSCRIPT\n"
        for segment in recording.segments {
            text += "[\(recording.speakerName(for: segment.speaker))] \(segment.text)\n"
        }
        return text
    }
}

private struct SummaryGroup: View {
    let title: String
    let items: [String]

    var body: some View {
        Text(title)
            .font(.subheadline)
            .fontWeight(.semibold)
        ForEach(items, id: \.self) { item in
            Text("• \(item)")
                .font(.subheadline)
        }
    }
}

// MARK: - Live tab

struct LiveView: View {
    @EnvironmentObject var store: RecordingStore
    @EnvironmentObject var transcription: TranscriptionService

    @StateObject private var live = LiveEngine()
    @State private var showingConsent = false
    @State private var chunkError: String?
    @AppStorage("dscribe.consentGiven") private var consentGiven = false

    private var transcriptText: String {
        live.liveSegments.map { $0.text }.joined(separator: " ")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if live.isLive {
                    RecordingIndicator()
                    Text(formatDuration(live.elapsed))
                        .font(.system(.largeTitle, design: .monospaced))
                    if live.isTranscribingChunk {
                        ProgressView("Transcribing last chunk…")
                            .font(.footnote)
                    }
                } else {
                    Text("Live mode transcribes as the meeting happens, and shows key points and questions to ask while it is still going.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                Button(action: liveButtonTapped) {
                    Text(live.isLive ? "Stop live session" : "Start live session")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(live.isLive ? Color.red : Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.horizontal)

                if live.isLive || !live.liveSegments.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(live.liveSegments) { segment in
                                    Text(segment.text)
                                        .font(.body)
                                        .id(segment.id)
                                }
                                if live.liveSegments.isEmpty {
                                    Text("Listening…")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                        }
                        .onChange(of: live.liveSegments.count) { _, _ in
                            if let last = live.liveSegments.last {
                                withAnimation {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        }
                    }

                    let keyPoints = SummaryEngine.keyPoints(
                        from: SummaryEngine.sentences(from: live.liveSegments)
                    )
                    if !keyPoints.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Key points so far")
                                .font(.headline)
                            ForEach(keyPoints, id: \.self) { point in
                                Text("• \(point)")
                                    .font(.subheadline)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                    }

                    let questions = SuggestedQuestions.suggestions(for: transcriptText)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Questions you could ask")
                            .font(.headline)
                        ForEach(questions, id: \.self) { question in
                            Text("• \(question)")
                                .font(.subheadline)
                        }
                        Text("Suggestions are template-based in v1.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                }
                Spacer()
            }
            .navigationTitle("Live")
            .sheet(isPresented: $showingConsent) {
                ConsentView(onConfirm: {
                    consentGiven = true
                    showingConsent = false
                    Task { await startLive() }
                })
            }
            .alert("Live transcription failed", isPresented: .constant(chunkError != nil)) {
                Button("OK", role: .cancel) { chunkError = nil }
            } message: {
                Text(chunkError ?? "")
            }
            .onAppear {
                live.onChunkError = { error in
                    chunkError = error.localizedDescription
                }
            }
        }
    }

    private func liveButtonTapped() {
        if live.isLive {
            finishLive()
        } else if !consentGiven {
            showingConsent = true
        } else {
            Task { await startLive() }
        }
    }

    private func startLive() async {
        guard await requestMicrophonePermission() else { return }
        do {
            try live.start(masterURL: store.newAudioURL(fileExtension: "wav"))
        } catch {
            chunkError = error.localizedDescription
        }
    }

    private func finishLive() {
        guard let result = live.stop() else { return }
        var recording = Recording(
            title: "Live session \(Date().formatted(date: .abbreviated, time: .shortened))",
            mode: .live,
            duration: result.duration,
            audioFileName: result.url.lastPathComponent,
            segments: live.liveSegments,
            isTranscribed: true
        )
        recording.summary = SummaryEngine.summarize(segments: recording.segments) { recording.speakerName(for: $0) }
        store.add(recording)
    }
}

// MARK: - Journal tab

struct JournalView: View {
    @EnvironmentObject var store: RecordingStore
    @EnvironmentObject var transcription: TranscriptionService

    @StateObject private var recorder = AudioRecorder()
    @State private var showingConsent = false
    @State private var isTranscribing = false
    @State private var transcribeError: String?
    @State private var completedReminders = Set<String>()
    @AppStorage("dscribe.consentGiven") private var consentGiven = false
    @AppStorage("dscribe.completedReminders") private var completedRemindersData = Data()

    private var entries: [Recording] {
        store.recordings(for: .journal)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        if recorder.isRecording {
                            RecordingIndicator()
                            Text(formatDuration(recorder.elapsed))
                                .font(.system(.largeTitle, design: .monospaced))
                            LevelMeter(level: recorder.level)
                                .padding(.horizontal)
                        } else {
                            Text("Talk for a minute about your day. Dscribe journals it, spots patterns, and reminds you of things you said you'd do.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        Button(action: journalButtonTapped) {
                            Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.white)
                                .frame(width: 72, height: 72)
                                .background(recorder.isRecording ? Color.red : Color.accentColor, in: Circle())
                        }
                        .buttonStyle(.plain)
                        if isTranscribing {
                            ProgressView("Transcribing on-device…")
                                .font(.footnote)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                let streak = JournalInsights.streakDays(entries: entries)
                if streak > 0 {
                    Section {
                        Label("\(streak)-day journaling streak", systemImage: "flame.fill")
                            .font(.subheadline)
                    }
                }

                let reminders = JournalInsights.commitments(from: entries)
                    .filter { !completedReminders.contains($0.id) }
                if !reminders.isEmpty {
                    Section("Things you said you'd do") {
                        ForEach(reminders) { reminder in
                            HStack(alignment: .top) {
                                Button {
                                    completeReminder(reminder)
                                } label: {
                                    Image(systemName: "circle")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                VStack(alignment: .leading) {
                                    Text(reminder.text)
                                    Text(reminder.entryDate.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                let topics = JournalInsights.topics(from: entries)
                if !topics.isEmpty {
                    Section("You keep mentioning") {
                        FlowChips(items: topics.map { "\($0.word) (\($0.count))" })
                    }
                }

                Section("Entries") {
                    if entries.isEmpty {
                        ContentUnavailableView(
                            "No journal entries yet",
                            systemImage: "book",
                            description: Text("Your first voice entry will appear here.")
                        )
                    } else {
                        ForEach(entries) { entry in
                            NavigationLink(value: entry.id) {
                                RecordingRow(recording: entry)
                            }
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                store.delete(entries[index])
                            }
                        }
                    }
                }
            }
            .navigationTitle("Journal")
            .navigationDestination(for: UUID.self) { id in
                RecordingDetailView(recordingID: id)
            }
            .sheet(isPresented: $showingConsent) {
                ConsentView(onConfirm: {
                    consentGiven = true
                    showingConsent = false
                    Task { await startJournal() }
                })
            }
            .alert("Transcription failed", isPresented: .constant(transcribeError != nil)) {
                Button("OK", role: .cancel) { transcribeError = nil }
            } message: {
                Text(transcribeError ?? "")
            }
            .onAppear {
                loadCompletedReminders()
            }
        }
    }

    private func journalButtonTapped() {
        if recorder.isRecording {
            finishJournal()
        } else if !consentGiven {
            showingConsent = true
        } else {
            Task { await startJournal() }
        }
    }

    private func startJournal() async {
        guard await requestMicrophonePermission() else { return }
        do {
            try recorder.start(to: store.newAudioURL(fileExtension: "m4a"))
        } catch {
            transcribeError = error.localizedDescription
        }
    }

    private func finishJournal() {
        guard let result = recorder.stop() else { return }
        let recording = Recording(
            title: "Journal \(Date().formatted(date: .abbreviated, time: .shortened))",
            mode: .journal,
            duration: result.duration,
            audioFileName: result.url.lastPathComponent
        )
        store.add(recording)
        isTranscribing = true
        Task {
            defer { isTranscribing = false }
            do {
                var updated = recording
                updated.segments = try await transcription.transcribeFile(url: result.url)
                updated.summary = SummaryEngine.summarize(segments: updated.segments) { updated.speakerName(for: $0) }
                updated.isTranscribed = true
                store.update(updated)
            } catch {
                transcribeError = error.localizedDescription
            }
        }
    }

    private func completeReminder(_ reminder: JournalReminder) {
        completedReminders.insert(reminder.id)
        saveCompletedReminders()
    }

    private func loadCompletedReminders() {
        if let decoded = try? JSONDecoder().decode(Set<String>.self, from: completedRemindersData) {
            completedReminders = decoded
        }
    }

    private func saveCompletedReminders() {
        completedRemindersData = (try? JSONEncoder().encode(completedReminders)) ?? Data()
    }
}

private struct FlowChips: View {
    let items: [String]

    var body: some View {
        FlexibleWrap(spacing: 8) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
        }
    }
}

/// Simple left-aligned wrapping layout for chips.
private struct FlexibleWrap<Content: View>: View {
    let spacing: CGFloat
    let content: () -> Content

    init(spacing: CGFloat = 8, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        // Chips flow into an adaptive grid so they wrap naturally.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: spacing)], alignment: .leading, spacing: spacing) {
            content()
        }
    }
}

// MARK: - Consent

struct ConsentView: View {
    var onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.accentColor)
                Text("Before you record")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("Dscribe records with your phone's microphones and transcribes everything on this phone. Nothing is uploaded anywhere.")
                Text("Recording laws are different in different places. In some places everyone in the room has to agree to be recorded. Please make sure the people around you know you are recording and have agreed to it.")
                Text("While recording, Dscribe shows a clear red recording indicator.")
                Spacer()
                Button("Everyone has agreed — start recording") {
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                Button("Not now", role: .cancel) {
                    dismiss()
                }
                .frame(maxWidth: .infinity)
            }
            .padding()
            .navigationTitle("Recording consent")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var store: RecordingStore
    @EnvironmentObject var transcription: TranscriptionService
    @EnvironmentObject var calendar: CalendarService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Transcription") {
                    Picker("Whisper model", selection: $transcription.selectedModel) {
                        ForEach(WhisperModel.allCases, id: \.self) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    HStack {
                        Text("Model status")
                        Spacer()
                        Text(statusText)
                            .foregroundStyle(.secondary)
                    }
                    if case .failed = transcription.whisperState {
                        Button("Retry download") {
                            Task { await transcription.ensureReady() }
                        }
                    }
                    if case .notDownloaded = transcription.whisperState {
                        Button("Download model now") {
                            Task { await transcription.ensureReady() }
                        }
                    }
                    Toggle("Use Apple on-device recognition instead", isOn: $transcription.preferApple)
                    Text("Whisper runs on-device with Core ML. The base model (~150 MB) downloads on first launch. Apple recognition needs no download and works offline, but is less accurate on noisy audio.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Calendar") {
                    Toggle("Auto-start for calendar meetings", isOn: $calendar.autoStartEnabled)
                    Text("When on, Dscribe starts recording by itself if the app is open when a meeting begins, and notifies you at the start time otherwise. Dscribe never records without your consent.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Storage") {
                    HStack {
                        Text("Recordings")
                        Spacer()
                        Text("\(store.recordings.count) · \(formatBytes(store.storageUsedBytes))")
                            .foregroundStyle(.secondary)
                    }
                    Text("Everything is stored on this phone. There is no cloud backup or sync in v1.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0")
                            .foregroundStyle(.secondary)
                    }
                    Text("Summaries in v1 are made on-device by picking the most important sentences you actually said. LLM-quality summaries come later with the Playground model and the ProDesk.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Speaker labels are a best guess from pauses between speakers. Tap any speaker name in a transcript to fix it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var statusText: String {
        switch transcription.whisperState {
        case .notDownloaded: return "Not downloaded"
        case .downloading: return "Downloading…"
        case .ready: return "Ready"
        case .appleFallback: return "Apple recognition"
        case .failed: return "Unavailable"
        }
    }
}
