# Codex Session Guardian

[简体中文](README.zh-CN.md)

**A privacy-first macOS menu bar companion for monitoring OpenAI Codex session health, context pressure, token usage, quota, and handoffs.**

Codex Session Guardian turns local Codex session telemetry into a lightweight menu bar dashboard and an animated desktop companion. It helps you notice overloaded contexts, repeated compaction, unusual fresh-input growth, and quota pressure before they disrupt a long-running task.

> [!IMPORTANT]
> This is an independent community project. It is not affiliated with, endorsed by, or sponsored by OpenAI or the owners of Crayon Shin-chan.

<p>
  <img src="Sources/TokenPet/Resources/PetAnimations/guardian/frame-00.png" alt="Dance Shin-chan theme" height="104">
  <img src="Sources/TokenPet/Resources/PetAnimations/shinchan-codex-v1/guardian/frame-00.png" alt="Pixel Shin-chan theme" height="104">
</p>

## Why it exists

Long Codex tasks can remain technically active while their context becomes expensive, repeatedly compacted, or difficult to resume safely. Raw token totals alone do not explain that risk. Session Guardian prioritizes the signals that change your next decision:

- context pressure for the latest user-visible turn;
- compaction count and post-compaction rebound;
- fresh input versus your local historical baseline;
- shared Codex quota and reset time;
- whether to continue, watch, or start a fresh task.

## Features

- **Global session view** — groups local Codex turns into user-facing sessions across projects.
- **Low-interference monitoring** — tails active logs, discovers sessions periodically, and skips unchanged history.
- **Session health model** — combines context pressure, compaction, fresh-input anomalies, and local calibration.
- **Accurate token semantics** — keeps cached input separate and uses provider `token_count` facts instead of estimating from text size.
- **Menu bar quota** — shows remaining quota at a glance with healthy, caution, and critical colors.
- **Floating active-session cards** — displays the latest state of every active task and keeps the card set stable while hovering or dragging.
- **Validated handoff** — can ask the source Codex task for a structured summary, validate it, create a fresh task, and deliver the handoff.
- **Two animation sets** — switches between Dance Shin-chan and Pixel Shin-chan, with the selected set persisted locally.
- **Local by design** — stores token facts and file cursors, not prompts, responses, source code, or tool payloads.

## Requirements

- macOS 14 or later
- Apple Silicon for the current packaging script
- Swift 6.2 toolchain
- Codex Desktop or Codex session logs under `~/.codex`
- SQLite 3
- `ffmpeg` only when regenerating the optional Pixel Shin-chan theme

## Build and run

```bash
swift build
.build/debug/CodexSessionGuardian
```

Run the executable test suite:

```bash
.build/debug/codex-session-guardian-tests
```

Create an ad-hoc signed app bundle:

```bash
scripts/package-app.sh dist/Codex-Session-Guardian.app
```

## How it works

```text
~/.codex session logs + state_5.sqlite
                  │
                  ▼
       incremental local scanner
                  │
                  ▼
   per-turn facts → session aggregation
                  │
                  ▼
 health policy + quota + activity state
          │                     │
          ▼                     ▼
  menu bar dashboard     floating guardian
```

The scanner reads local rollout JSONL files incrementally and records only derived usage facts and cursors in SQLite. The UI presents one latest turn per session while recent turns remain background evidence for health calibration.

## Data and privacy

Session Guardian reads:

- `~/.codex/sessions/**/*.jsonl`
- `~/.codex/archived_sessions/**/*.jsonl`
- `~/.codex/state_5.sqlite`
- `~/.codex/session_index.jsonl`

It writes its local index to the legacy-compatible directory:

```text
~/Library/Application Support/TokenPet/token-pet.sqlite
```

The app does not upload session data. Network access is not part of normal monitoring. The theme import script downloads a pinned public spritesheet only when you run that script manually.

The optional handoff action communicates with the local Codex Desktop owner process or local Codex app-server. It runs only after an explicit user action and never archives or deletes the source task automatically.

See [SECURITY.md](SECURITY.md) for reporting and privacy details.

## Animation themes

The repository includes two Shin-chan-inspired fan-art animation sets. They are intentionally licensed separately from the software.

To deterministically regenerate the Pixel Shin-chan frames:

```bash
scripts/import-shinchan-codex-pet.sh
```

The script verifies the upstream spritesheet with SHA-256 before extracting the six semantic states used by the app.

## License

- Source code and documentation: [MIT License](LICENSE)
- Character images and animation assets: personal, non-commercial fan use only; see [ASSETS_LICENSE.md](ASSETS_LICENSE.md)

The asset restriction means the repository uses a **mixed license**. The software code is open source, while the included character artwork is not open source under the OSI definition.

## Contributing

Bug reports and focused pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting changes.

Useful GitHub topics: `openai-codex`, `codex`, `macos`, `swiftui`, `menu-bar-app`, `token-usage`, `session-monitoring`, `privacy`, `developer-tools`.
