# Changelog

Each release's notes come from its `## <version>` section here, so add one before bumping `MARKETING_VERSION`.

## 1.4.0
- **Pause and resume.** While recording, the menu shows **Pause** next to **Stop Recording**; paused time is left out, and you still get one recording. The timer shows the recorded time only, and the menu bar icon shows pause bars. In the shortcut popup, press **P**.

## 1.3.0
- **Smaller recordings.** When a recording finishes, its audio is now converted to M4A, typically a tenth of the size or less, and playable anywhere. Recording itself still writes CAF, so a crash can't cost you a meeting; the conversion happens after the mix and transcript are made.
- **This replaces the lossless originals for new recordings.** To keep them, choose **CAF (lossless)** under Settings > Audio > Format.
- Recordings you already have are left alone. **Compress to M4A…** in Settings > Audio converts them when you ask.
- New setting, **Include microphone in transcripts** (Settings > Transcription, on by default). Turn it off to transcribe only the meeting audio, which avoids repeated lines when your microphone picks up the meeting from the speakers.

## 1.2.0
- **Playback.** Each recording in the Recordings window has a play button. The recording you're listening to shows the elapsed time and a scrubber to jump around.
- **Quicker delete.** The trash icon now moves a recording to the Trash straight away and shows an Undo message for a few seconds (⌘Z works too).
- Rows can no longer be selected, so deleting several recordings at once is gone; delete them one at a time.
- Playback is off while Rekord is recording, so it can't end up in the new recording, and it stops when you close the window.

## 1.1.0
- **Transcripts.** On macOS 26 or later, each new recording gets a `transcript.txt`, made on your Mac with Apple's speech model. With the microphone included, lines are labelled **Me** (your microphone) and **Others** (the meeting audio). Open it from the Recordings list.
- Choose the language, hide the timestamps, or turn automatic transcription off, in Settings > Transcription. Older recordings have a Transcribe button in the Recordings list.
- **Recordings window.** Quieter rows grouped by day, Finder and Trash on hover or right-click, and bulk delete: select several recordings (⌘-click, ⇧-click, ⌘A) and press Delete. Every delete asks first and goes to the Trash.
- **Settings** is now four tabs (General, Audio, Transcription, Privacy), and the Privacy tab shows the state of each permission.
- Your audio still never leaves your Mac. macOS may download a language model from Apple the first time.

## 1.0.2
- The menu bar icon's dot turns orange instead of red while a recording is receiving no system audio, which usually means the System Audio Recording permission is missing. It turns red as soon as audio arrives.

## 1.0.1
- Recordings that include the microphone are now mixed into `combined.caf` automatically, a moment after you stop. The Combine button is gone. Older recordings that were never combined are mixed the next time Rekord lists them.
- Each microphone recording therefore takes roughly twice the disk space it did before.

## 1.0.0
- First stable release. Rekord is now also prepared for the Mac App Store: the output folder you choose in Settings is remembered securely, which lets the sandboxed App Store build save recordings where you want them.
- Added a privacy policy (`PRIVACY.md`): Rekord collects nothing and never sends your recordings anywhere.
- Recording, Combine, the shortcut and everything else work as before.

## 0.2.2
- First signed and notarized release. Rekord is signed with a Developer ID and notarized by Apple, so it opens without the "Apple could not verify" warning.
- macOS may ask for the Microphone and System Audio Recording permissions once more, because the app's signature changed. If a recording comes out silent, remove Rekord from the entries in System Settings > Privacy & Security and add it again.
- No changes to how the app works.

## 0.2.1
- Redesigned the ⇧⌘9 shortcut popup as a fast audio-source chooser: System Audio and System Audio + Microphone rows, with `1` / `2` to start, arrow keys and Return to choose, and Esc to cancel.
- The popup remembers your last choice, opens beside the cursor without covering it, and stays fully on screen near edges.
- README now includes screenshots.

## 0.2.0
- Redesigned menu bar popup: a clear status line (Ready, Starting, Recording with a timer, or a warning), one prominent Start / Stop Recording button, a compact microphone switch showing which mic will be used, and lighter Recent Recordings, Settings and Quit rows.
- Clearer warnings: a specific message when the microphone or System Audio Recording permission is the problem, and a neutral one when no system audio is arriving.
- A "Starting…" state while macOS shows the microphone permission prompt.

## 0.1.0
- First release: record system audio and the microphone as separate tracks, with an optional one-click Combine.
- Menu bar app with a global shortcut (default ⇧⌘9, changeable), recordings window, microphone picker and launch at login.
- Warnings when a permission is missing.
