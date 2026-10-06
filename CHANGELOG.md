# Changelog

Each release's notes come from its `## <version>` section here, so add one before bumping `MARKETING_VERSION`.

## 1.8.2
- **Fixed a freeze on "Starting recording…".** After choosing a microphone by name in the menu or in Settings, Rekord could hang when a recording started, if that microphone was already your Mac's default input. If you were hit by this, a recording cut short by the freeze is listed the next time Rekord opens.
- **The version is shown in Settings > General.**
- Rekord now notes each step of starting a recording in the macOS log on your Mac, and when it stops responding, so a problem like this one can be traced. The notes hold step names and timings only, never audio or file names, and are not sent anywhere.

## 1.8.1
- The input device in Settings > Audio is locked while a recording is running, like the microphone menu. A recording keeps the microphone it started with, so changing it there used to make the name shown disagree with what was being recorded.

## 1.8.0
- **Choose the microphone from the menu.** The microphone's name in the menu is now a list of your input devices: click it to switch, for example to your headset, right before you record. **System Default** follows your Mac's input. It is the same setting as Settings > Audio, and it can't be changed while a recording is running.

## 1.7.1
- **A crash no longer hides a recording.** If Rekord or your Mac goes down mid-recording, what was captured is listed the next time Rekord opens. Before, the audio was on disk but never appeared in the app.
- **Rekord stops and tells you when it can't save**, for example when the disk is full, instead of carrying on with nothing being written.
- **Old audio is removed more carefully.** A transcript that found no speech no longer counts, and a transcript made from an old recording keeps its audio for the full period, so you can check one against the other.
- The save folder can't be changed while a recording is running; doing so used to leave that recording out of the list.
- A Mac with no microphone gets a clear message when the microphone is switched on.
- Deleting a recording while it is being mixed no longer shows an error.
- **The Recordings list shows what each recording has.** Every row says whether it has a transcript, can be transcribed, is being transcribed or is waiting its turn, without you pointing at it. Mixing and converting are named under the recording, the one being played stays highlighted, and a mix that fails names the recording.
- **Trashing is smoother.** The row fades out as the Undo message comes in, and Undo puts it back the same way. Pointing at the Undo message keeps it open.
- **The menu keeps the timer when something is wrong.** If a recording receives no system audio, the warning appears under the timer instead of in its place. The menu is also more compact, the source reads **All System Audio**, and Source and Microphone say why they are off while recording.
- **Settings are easier to read.** Each explanation sits under its setting instead of in a row of its own. System Audio reports whether your last recording received audio, since macOS doesn't tell Rekord whether it is allowed, and **Compress to M4A…** is now **Convert to M4A…**.

## 1.7.0
- **Record one app.** Choose an app under **Source** in the menu to record only its audio, such as your meeting app, and leave out everything else your Mac plays. **All Audio** is still the default, and the shortcut popup shows which source is set.
- The app has to be open when you start. If it isn't, Rekord tells you instead of recording everything.
- A meeting in a browser records every tab of that browser. Safari can't be chosen, because its audio comes from a shared system process.
- `session.json` notes the app a recording was made from.

## 1.6.0
- **Audio is now removed after 7 days.** Once a recording has a transcript and is more than a week old, its audio files are moved to the Trash; the transcript and the name stay. **This applies to recordings you already have**, the first time Rekord lists them after updating. Change the period, or choose Never, under Settings > Audio > Delete audio after. Recordings without a transcript always keep their audio.
- **No more doubled lines.** With speakers, your microphone hears the meeting, and each sentence used to appear twice in the transcript. Rekord now leaves out a microphone line that repeats what the meeting audio said at the same moment. It cleans the transcript only, not the audio, and an echo the recogniser garbled can still slip through.
- **Paragraphs.** A transcript is written as one paragraph per stretch of a speaker, with one timestamp each, instead of a line per sentence.
- **Copy Transcript.** Right-click a recording to copy its transcript, headed by its name, date and length, ready to paste into an AI assistant.
- Transcripts already on disk keep their old layout.

## 1.5.0
- **Name your recordings.** Double-click a recording's time (or choose Rename… from the right-click menu) and type a name. It is only a label inside Rekord: files and folders keep their names. Clear the name to go back to the time.
- **Tooltips work.** Hovering a button in the Recordings or Settings window now shows what it does. They never appeared before, because macOS hides tooltips in a window whose app isn't the active one.
- **Simpler rows.** Recordings are always grouped by day, so a row shows just the time (or name), the length, and a microphone symbol when the microphone was included.

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
