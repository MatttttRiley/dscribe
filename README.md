# Dscribe

One app, three modes: an **AI meeting recorder**, a **live meeting helper**,
and a **voice journal**. SwiftUI, iOS 17+, built for the Apple Human Interface
Guidelines. Everything is on-device — recordings, transcripts, and summaries
never leave the phone.

## The three modes

- **Record** — Record a meeting, a class, or anything important with the
  phone's mics. Recording keeps going with the screen locked (background
  audio) and pauses gracefully on phone calls, resuming when the call ends.
  After recording, the audio is transcribed on-device and turned into a
  summary: key points, decisions, action items with owners, and open
  questions. Transcripts are searchable, and speaker labels can be fixed by
  hand (on-device speaker separation is a best guess — tap any speaker name
  to rename it).
- **Live** — Transcribes as the meeting happens in rolling 12-second chunks,
  and shows rolling key points plus questions you could ask while the meeting
  is still going. When you stop, the session is saved like a normal recording.
- **Journal** — Voice journal entries. Dscribe spots patterns across entries
  (things you keep mentioning) and surfaces reminders of things you said
  you'd do, with a journaling streak.

## How transcription works

Transcription is **Whisper via WhisperKit** (Core ML, MIT-licensed), running
entirely on the phone. The base model (~150 MB) downloads from Hugging Face
on first launch; the small model (~500 MB) is offered in Settings. If Whisper
is unavailable (no model yet, no network), the app falls back to Apple's
on-device Speech framework, which needs no download.

## How summaries work (v1)

Summaries in v1 are **extractive and template-based**: the app picks and
sorts sentences you actually said — key points by importance, decisions and
action items by phrasing, open questions by question marks. No LLM runs on
the phone yet. The summary engine is a separate type with a single entry
point, so an LLM engine (Playground model / ProDesk) can replace it later
without touching the UI or the data model.

## Privacy

- Recordings, transcripts, and summaries stay in the app's Documents folder
  on the device. No cloud, no sync, no analytics in v1.
- A clear red recording indicator shows while recording.
- The first time you record, Dscribe asks you to confirm that everyone
  present has agreed to be recorded — recording laws differ by place.
- Calendar auto-start is opt-in. When on, Dscribe starts recording by
  itself if the app is open when a meeting begins, and sends a local
  notification at the start time otherwise. It never records without your
  consent.

## Build

GitHub Actions builds an unsigned IPA on every push to `main`
(`macos-26`, no code signing). Install it with SideStore, which re-signs it
on your own computer with your Apple ID.

## Tested vs untested (honest)

Verified:
- The project compiles and packages on GitHub Actions (macos-26).
- The IPA is a valid arm64 app bundle with the right bundle ID.

Not yet verified (needs a real phone — Matt installs and confirms):
- Recording with the mic, background recording with the screen locked,
  and pause/resume on phone calls.
- Whisper model download and transcription quality on real speech.
- Speaker-label accuracy.
- Summary quality on real meetings.
- Live mode chunk transcription, key points, and suggested questions.
- Journal patterns and reminders.
- Calendar auto-start.
