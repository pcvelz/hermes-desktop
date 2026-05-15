# Hermes Desktop v0.8.1

`v0.8.1` tightens a few important edges without changing the product model.

Hermes Desktop still connects directly to the selected Hermes host over SSH.
The host remains the source of truth. This release does not add a gateway API,
helper daemon, local mirror, or background sync layer.

## Highlights

- supports custom Hermes home paths more cleanly, including profile-aware path
  resolution and terminal/bootstrap flows
- hardens workflow launch prompt delivery and adds better diagnostics around
  startup handoff into Terminal
- avoids treating a failed automatic update check as a successful one, so the
  app can retry later instead of silently suppressing checks for a day

## Compatibility

- the app still requires SSH access from this Mac to the Hermes host, with
  `python3` available on the host
- in-app chat, terminal resume, and workflow launch paths still require the
  remote `hermes` CLI to be available on the host's non-interactive SSH `PATH`
- public releases are still ad-hoc signed and not notarized by Apple

## Still true

- Hermes Desktop still connects directly over SSH
- the Hermes host remains the source of truth
- sessions, Kanban, cron jobs, files, skills, usage, and terminal work stay
  anchored to the selected host and profile
- workflow presets remain local launch helpers, not a second transport model or
  synchronization layer

## Notes

- universal macOS build for Apple Silicon and Intel
- ad-hoc signed and not notarized yet, so first launch may still require
  right-click -> Open / Open Anyway
- release archive: `HermesDesktop.app.zip`
- checksum: `HermesDesktop.app.zip.sha256`
- manifest: `HermesDesktop.app.zip.manifest.json`
