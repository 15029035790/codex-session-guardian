# Security and Privacy

## Supported version

Security fixes target the latest version on the `main` branch.

## Reporting a vulnerability

Please use GitHub private vulnerability reporting when available. Do not open a public issue containing credentials, Codex conversation content, private task titles, filesystem paths, or reproduction archives with local session data.

## Local data boundary

Codex Session Guardian reads local Codex session metadata and token events. Its SQLite index stores derived token facts, status, timestamps, and file cursors. It is not designed to store prompts, responses, tool payloads, or monitored project source code.

Normal monitoring performs no upload. The optional asset import script accesses its documented public GitHub URL only when invoked manually. The handoff workflow communicates with local Codex Desktop or a local Codex app-server only after explicit user action.

Before attaching logs to an issue, remove session IDs, task titles, usernames, home-directory paths, and any conversation or tool content.
