# Privacy and Data Handling

MeetingScribe is a local-first macOS application. Audio extraction, Whisper
transcription, speaker diarization, voice matching, frame selection, and OCR
run locally. Depending on the selected generation backend, text and selected
images may be sent to an online model provider to produce meeting minutes or
perform project analysis.

The directly distributed build uses Apple's hardened runtime but is not a Mac
App Store sandboxed application because it invokes locally installed CLI tools
and processes files selected by the user. Those tools run with the permissions
of the signed-in macOS user.

## Data that can leave the Mac

- API backends receive the prompt and the meeting content required by the
  selected processing node. Vision-capable API models may also receive selected
  frames or image materials.
- CLI backends receive text input. MeetingScribe invokes them in an ephemeral,
  read-only session, but the CLI provider's own account and privacy terms still
  apply.
- API credentials are stored in macOS Keychain and are not included in backups
  or debug logs.

Before processing a meeting, the user is responsible for confirming that its
participants and organisation permit transcription and transmission to the
selected provider.

## Local sensitive data

Meeting records, transcripts, materials, recognition memories, voice profiles,
and project ledgers are stored under the user's Application Support directory.
Voice profiles are biometric-derived data and should be handled accordingly.

Library backups are ordinary ZIP archives and are **not encrypted**. Store them
only in an encrypted and access-controlled location.

When hidden pipeline debugging is enabled, MeetingScribe writes full prompts,
transcripts, model outputs, tool output, and file paths to the `Debug` directory.
Debug files are private to the local user and old runs are pruned automatically,
but users should still clear them after troubleshooting.

## Deletion

Users can remove meetings, recognition memories, and voice profiles from the
application. Uninstalling the app does not automatically delete its Application
Support, cache, Keychain, or user-created backup files.
