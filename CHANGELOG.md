# Changelog

Each release's notes come from its `## <version>` section here, so add one before bumping `MARKETING_VERSION`.

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
