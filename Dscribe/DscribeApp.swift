import SwiftUI

/// Dscribe — one app, three modes:
/// Record (AI meeting recorder), Live (live meeting helper), Journal (voice journal).
/// Everything is on-device. Transcription is Whisper via WhisperKit (Core ML),
/// with Apple's on-device Speech framework as a fallback.
/// Summaries in v1 are extractive/template-based; the SummaryEngine protocol
/// exists so an LLM engine (Playground model / ProDesk) can replace it later.
@main
struct DscribeApp: App {
    @StateObject private var store = RecordingStore()
    @StateObject private var transcription = TranscriptionService()
    @StateObject private var calendar = CalendarService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(transcription)
                .environmentObject(calendar)
        }
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            RecordView()
                .tabItem { Label("Record", systemImage: "mic.fill") }
            LiveView()
                .tabItem { Label("Live", systemImage: "waveform") }
            JournalView()
                .tabItem { Label("Journal", systemImage: "book.fill") }
        }
    }
}
