# Security Policy

## Supported version

Security fixes are made on the latest version of the `main` branch. Preview
builds are provided for evaluation and should not be treated as a substitute
for an organisation's approved records or security controls.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability or accidental data
exposure. Use GitHub's private vulnerability reporting for this repository.
Include the affected version, reproduction steps, impact, and any relevant
logs after removing meeting content, credentials, customer names, and personal
information.

Do not upload MeetingScribe backups, debug directories, transcripts, audio,
video, screenshots, voice profiles, or API keys to a public issue.

## Sensitive local data

MeetingScribe may store meeting records, transcripts, selected frames, voice
profiles, prompt diagnostics, and model responses in the user's Application
Support directory. Debug logging is disabled by default. Users should disable
it after troubleshooting and delete diagnostic runs before sharing a computer
or support bundle.
