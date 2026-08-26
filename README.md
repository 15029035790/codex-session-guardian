# Codex Session Guardian

[简体中文](README.zh-CN.md)

**A privacy-first macOS companion that helps Codex use the lowest sufficient execution configuration, explains local Token cost, and surfaces only actionable session problems.**

Codex Session Guardian turns local Codex telemetry into a menu bar dashboard and a small desktop companion, Xiaoxin. It observes task health, quota, model/effort choices, and multi-agent execution without uploading prompts, source code, tool payloads, or responses.

> [!IMPORTANT]
> This is an independent community project. It is not affiliated with, endorsed by, or sponsored by OpenAI or the owners of Crayon Shin-chan.

<p>
  <img src="Sources/TokenPet/Resources/PetAnimations/guardian/frame-00.png" alt="Dance Shin-chan theme" height="104">
  <img src="Sources/TokenPet/Resources/PetAnimations/shinchan-codex-v1/guardian/frame-00.png" alt="Pixel Shin-chan theme" height="104">
</p>

## What it does

- **Global session view** — groups local Codex turns into user-facing sessions across projects.
- **Accurate Token accounting** — uses provider `token_count` facts and keeps cached input separate from fresh work.
- **Session health** — combines context pressure, compaction, fresh-input anomalies, quota, and local calibration.
- **Live task activity** — shows semantic task stages and at most two lines of public assistant output; private reasoning and raw tool data are excluded.
- **Action-first attention** — expands Xiaoxin for approvals, unanswered questions, failures, and verified configuration problems instead of turning routine activity into an inbox.
- **Execution routing evidence** — records local `sol/medium`, `luna/max`, and `terra/high` habits as evaluation candidates, never as universal recommendations.
- **Multi-agent audit** — correlates parent `spawn_agent` calls with child rollouts and reports broad fan-out, full-history inheritance, and measured Token burn.
- **Codex-managed handoff** — on explicit user action, sends only “Summarize the necessary context and start a new task.” Codex owns the summary and destination task.
- **Local by design** — persists aggregate facts and cursors, not task content.

The product is an adaptive execution optimizer, not a general desktop-pet platform. Pet stores, character generation, broad spritesheet compatibility, and desktop-world progression are out of scope unless they directly improve execution quality or efficiency.

Product and evidence boundaries are documented in [PRODUCT_CONSTITUTION.md](docs/PRODUCT_CONSTITUTION.md), [TECHNICAL_SPIKES.md](docs/TECHNICAL_SPIKES.md), [TOKEN_EFFICIENCY_STRATEGY.md](docs/TOKEN_EFFICIENCY_STRATEGY.md), and [HANDOFF_STRATEGY.md](docs/HANDOFF_STRATEGY.md).

## Download and install

[**Download the latest macOS build for Apple Silicon**](https://github.com/15029035790/codex-session-guardian/releases/latest/download/Codex-Session-Guardian-macos-arm64.zip)

1. Unzip `Codex-Session-Guardian-macos-arm64.zip`.
2. Move **Codex Session Guardian.app** to `/Applications`.
3. Launch it from Applications. On first launch, Control-click the app and choose **Open**. If macOS still blocks it, use **System Settings → Privacy & Security → Open Anyway**.

The community build is ad-hoc signed and not Apple-notarized. Verify the archive against the `.sha256` file attached to the [latest release](https://github.com/15029035790/codex-session-guardian/releases/latest).

### Requirements

- macOS 14 or later
- Apple Silicon
- Codex Desktop or Codex session logs under `~/.codex`
- SQLite 3

## Current behavior that matters

### Subagent lifecycle health

Guardian can install observation-only `SubagentStart` and `SubagentStop` handlers. They never block, modify, or start a task. Health is based on whether an expected lifecycle event reached Guardian, not on a heartbeat timeout:

- a delivered start remains healthy while a child task runs;
- a stop event is not expected until that child finishes;
- a newer rollout lifecycle event without the corresponding Hook delivery is reported as inactive;
- **Got it** suppresses one unchanged warning fingerprint, while a changed health state becomes visible again.

Guardian uses Codex `hooks/list` to distinguish missing configuration, untrusted handlers, the absence of child activity, and a lifecycle event that failed to arrive. It does not edit `config.toml` or fabricate trust state.

### Low-noise multi-agent findings

The local shadow audit retains full provider usage for diagnosis. A bounded child whose usage is dominated by cached input stays in postflight review instead of raising a running card. A running large-Token warning additionally requires at least **1M non-cached provider tokens** (`fresh input + output + reasoning output`). Guardian never interrupts a task or changes an Agent, model, or effort automatically.

### Privacy-safe live UI

The menu bar reports quota and local aggregate evidence. Floating cards show current session state, stay stable during hover and drag, and can be hidden or restored. The live tailer ignores reasoning, command bodies, tool arguments, raw tool output, stdout, and stderr.

## Build and test

Building from source requires the Swift 6.2 toolchain. `ffmpeg` is needed only when regenerating the optional Pixel Shin-chan theme.

```bash
swift build
.build/debug/CodexSessionGuardian
```

Run the executable test suite:

```bash
swift run --disable-sandbox codex-session-guardian-tests
```

Create an optimized, ad-hoc signed app bundle:

```bash
scripts/package-app.sh dist/Codex-Session-Guardian.app
```

## Hook setup

Install the synchronous routing preflight handler:

```bash
"outputs/installed/Codex Session Guardian.app/Contents/Helpers/codex-session-guardian-cli" \
  --install-user-prompt-hook \
  --hook-command "$PWD/outputs/installed/Codex Session Guardian.app/Contents/Helpers/codex-session-guardian-cli" \
  --hooks-file "$HOME/.codex/hooks.json"
```

Install observation-only child lifecycle handlers:

```bash
"outputs/installed/Codex Session Guardian.app/Contents/Helpers/codex-session-guardian-cli" \
  --install-subagent-hooks \
  --hook-command "$PWD/outputs/installed/Codex Session Guardian.app/Contents/Helpers/codex-session-guardian-cli" \
  --hooks-file "$HOME/.codex/hooks.json"
```

Then review and trust the handlers in Codex CLI `/hooks`. Restart Codex Desktop once after installing or changing them so new tasks load the updated Hook snapshot. The current Hook payload does not expose `fork_turns`; Guardian correlates the lifecycle ledger with the parent rollout rather than inventing that value.

Useful diagnostics:

```bash
.build/debug/codex-session-guardian-cli --routing-hook-diagnostics
.build/debug/codex-session-guardian-cli --subagent-hook-diagnostics --limit 100
.build/debug/codex-session-guardian-cli --subagent-hook-health
```

## Local audits

All reports below are local and aggregate-only:

```bash
# Model, effort, task-shape, validation, and provider-Token audit
.build/debug/codex-session-guardian-cli --token-audit --token-audit-days 90

# Parent/child execution strategy and Token findings
swift run --disable-sandbox codex-session-guardian-cli \
  --multi-agent-audit --multi-agent-audit-days 7 --limit 10000

# Handoff shadow decisions
.build/debug/codex-session-guardian-cli --shadow-report

# Evidence-backed execution-waste observations
.build/debug/codex-session-guardian-cli --execution-waste --only-with-evidence --limit 20
.build/debug/codex-session-guardian-cli --execution-waste-review --only-unlabeled --limit 20
.build/debug/codex-session-guardian-cli --execution-waste-accuracy
```

To inspect the declared routing policy for a specific task contract:

```bash
.build/debug/codex-session-guardian-cli --set-routing-profile current-habits
.build/debug/codex-session-guardian-cli --routing-profile
.build/debug/codex-session-guardian-cli --route-task-contract /path/to/task-contract.json
```

These outputs explain recorded habits and evaluation candidates. They do not prove that a configuration is optimal for another task or user.

## How it works

```text
~/.codex rollout logs + state_5.sqlite
                    │
                    ▼
         incremental local scanner
                    │
          ┌─────────┴─────────┐
          ▼                   ▼
  aggregate SQLite facts   in-memory live tail
          │                   │
          └─────────┬─────────┘
                    ▼
       policy and evidence models
                    │
          ┌─────────┴─────────┐
          ▼                   ▼
   menu bar dashboard   floating Xiaoxin
```

The scanner reads complete JSONL records incrementally and stores derived usage facts plus safe file cursors. The live tailer follows active sessions for UI updates without persisting public-output previews.

## Data and privacy

Guardian reads:

- `~/.codex/sessions/**/*.jsonl`
- `~/.codex/archived_sessions/**/*.jsonl`
- `~/.codex/state_5.sqlite`
- `~/.codex/session_index.jsonl`

Its local index is stored at:

```text
~/Library/Application Support/TokenPet/token-pet.sqlite
```

Normal monitoring has no network dependency and does not upload session data. Persistent ledgers are bounded and contain derived counts, timestamps, enums, hashes, provider Token categories, and fixed review labels. They exclude titles, working directories, prompts, replies, source code, command bodies, tool arguments, and raw tool output. See [SECURITY.md](SECURITY.md) for the reporting and privacy policy.

## Themes and licensing

The repository includes two Shin-chan-inspired fan-art animation sets. They are licensed separately from the software. The optional import script downloads a pinned public spritesheet only when run manually and verifies it with SHA-256:

```bash
scripts/import-shinchan-codex-pet.sh
```

- Source code and documentation: [MIT License](LICENSE)
- Character images and animation assets: personal, non-commercial fan use only; see [ASSETS_LICENSE.md](ASSETS_LICENSE.md)

This is therefore a **mixed-license repository**: the software is open source, while the included character artwork is not open source under the OSI definition.

## Contributing

Focused issues and pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before contributing.
