# Codex Session Guardian

[简体中文](README.zh-CN.md)

**A privacy-first macOS Token efficiency guardian for Codex that learns personal task patterns and reduces avoidable usage without lowering task quality.**

Codex Session Guardian turns local Codex task telemetry into a personal task-economics model, a lightweight menu bar dashboard, and an animated desktop companion. Its goal is to recommend the lowest sufficient model configuration, explain execution cost, and intervene only when a long task shows real continuity damage.

> [!IMPORTANT]
> This is an independent community project. It is not affiliated with, endorsed by, or sponsored by OpenAI or the owners of Crayon Shin-chan.

<p>
  <img src="Sources/TokenPet/Resources/PetAnimations/guardian/frame-00.png" alt="Dance Shin-chan theme" height="104">
  <img src="Sources/TokenPet/Resources/PetAnimations/shinchan-codex-v1/guardian/frame-00.png" alt="Pixel Shin-chan theme" height="104">
</p>

## Product boundary

Internally, Session Guardian is **an adaptive Codex execution optimizer that learns how its user works**. The pet, multi-task radar, and live activity are low-interference surfaces; the core value is choosing the lowest sufficient model and reasoning effort, checking whether Token usage produces verified results, and finding systemic waste in execution and collaboration configuration.

See the Chinese-first [Token efficiency strategy and phased execution plan](docs/TOKEN_EFFICIENCY_STRATEGY.md) for the product north star and stage gates. Handoff is a low-frequency recovery mechanism within execution health; its protocol and safety constraints remain in the [handoff-specific strategy](docs/HANDOFF_STRATEGY.md).

It does not aim to mirror every feature in the fast-growing [Awesome Codex Pet](https://github.com/legeling/awesome-codex-pet) ecosystem. Pet stores, character generators, broad spritesheet compatibility, and desktop-world progression are explicit non-goals unless they later support the Guardian core.

## Download

[**Download the latest macOS app (Apple Silicon)**](https://github.com/15029035790/codex-session-guardian/releases/latest/download/Codex-Session-Guardian-macos-arm64.zip)

1. Unzip `Codex-Session-Guardian-macos-arm64.zip`.
2. Move **Codex Session Guardian.app** to `/Applications`.
3. Launch it from Applications. On the first launch, Control-click the app and choose **Open**. If macOS still blocks it, go to **System Settings → Privacy & Security** and choose **Open Anyway**.

The current community build is ad-hoc signed but not Apple-notarized. You can compare its SHA-256 digest with the `.sha256` file attached to the [latest release](https://github.com/15029035790/codex-session-guardian/releases/latest).

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
- **Floating active-session cards** — displays the latest state of every active task, keeps the card set stable while hovering or dragging, and can be hidden or restored from the menu bar panel.
- **Private live activity** — updates each active card from its rollout stream with a real semantic stage, last-update time, and at most two lines of public assistant output; reasoning, tool arguments, and raw tool output are ignored.
- **Action-first attention** — waits for your approval or answer and task failures immediately expand the floating Xiaoxin card and show a speech bubble; routine activity and completion history do not create an inbox.
- **Quality-first low-frequency handoff** — asks the source task's model for a structured summary, strictly validates all required sections, then injects it into the fresh task without a confirmation-only model turn; the heuristic local capsule is no longer the default summary.
- **Two animation sets** — switches between Dance Shin-chan and Pixel Shin-chan, with the selected set persisted locally.
- **State-aware Shin-chan personality** — adds Chinese-first quips for work, multitasking, refreshes, risk, handoff, completion, hover, drag, and double-click interactions, with off, light, and active intensity levels.
- **Local by design** — stores token facts and file cursors, not prompts, responses, source code, or tool payloads.
- **Chinese-first UI** — uses Simplified Chinese by default, with optional English support when macOS explicitly prefers English.

## System requirements

- macOS 14 or later
- Apple Silicon
- Codex Desktop or Codex session logs under `~/.codex`
- SQLite 3

## Build from source

Building from source additionally requires the Swift 6.2 toolchain. `ffmpeg` is needed only when regenerating the optional Pixel Shin-chan theme.

```bash
swift build
.build/debug/CodexSessionGuardian
```

Run the executable test suite:

```bash
.build/debug/codex-session-guardian-tests
```

Inspect the local, aggregate-only handoff shadow report:

```bash
.build/debug/codex-session-guardian-cli --shadow-report
```

Run a privacy-safe model, reasoning-effort, behavioral task-shape, validation-signal, and Token audit over the last 90 days:

```bash
.build/debug/codex-session-guardian-cli --token-audit --token-audit-days 90
```

The aggregate report excludes titles, paths, prompts, command bodies, raw tool output, and replies. It reports observed-habit coverage and official evaluation candidates; a habit is never treated as a recommendation.

Persist and inspect the current controller-worker habits as an evaluation baseline:

```bash
.build/debug/codex-session-guardian-cli --set-routing-profile current-habits
.build/debug/codex-session-guardian-cli --routing-profile
```

Run the locally declared routing policy against an explicit task contract:

```bash
.build/debug/codex-session-guardian-cli --route-task-contract /path/to/task-contract.json
```

The result explains how `codex-quota-router` would route the task and remains marked as unvalidated until representative quality/Token evaluations pass.

The production bundle contains a synchronous configuration preflight hook. It blocks only high-confidence route mismatches and recommends the sufficient route; uncertainty, schema drift, timeout, or classifier failure all fail open. The installer backs up `~/.codex/hooks.json`, preserves existing handlers, and never fabricates Codex trust state:

```bash
"outputs/installed/Codex Session Guardian.app/Contents/Helpers/codex-session-guardian-cli" \
  --install-user-prompt-hook \
  --hook-command "$PWD/outputs/installed/Codex Session Guardian.app/Contents/Helpers/codex-session-guardian-cli" \
  --hooks-file "$HOME/.codex/hooks.json"
```

After installing or changing the handler, review and trust it from `/hooks` in the Codex CLI. Use `--routing-preflights --limit 20` to inspect the prompt-free local decision ledger; model fallbacks also record their provider Token usage so preflight overhead remains measurable.

Guardian v0.3 also checks whether the installed handler has delivered any event after installation. If Codex Desktop keeps using its pre-install Hook snapshot, Xiaoxin shows a chain-health warning and asks for one full Desktop restart plus a verification prompt; this is distinct from a clean “configuration is appropriate” result.

The local execution-strategy shadow ledger now correlates parent `spawn_agent` calls with child rollouts. It flags full-history inheritance, broad concurrent fan-out, and large provider-token burn. High-confidence findings can surface while work is running with two user-owned choices: interrupt the parent task or continue observing. Guardian never interrupts a task or changes an Agent/model configuration on its own. Completed findings remain in the menu-bar audit card. For local diagnosis:

```bash
swift run --disable-sandbox codex-session-guardian-cli \
  --multi-agent-audit --multi-agent-audit-days 7 --limit 10000
```

The default entry route is `terra/medium`. High-confidence underpowered routes can be upgraded first to `terra/high`, then to `sol/medium`; overpowered routes can still be downgraded. On a mismatch, Xiaoxin opens a floating confirmation card before execution with the current route, suggested route, and reason. “Switch & replay” overrides model and effort for that task and replays only the blocked message. The message crosses a user-only (`0600`) local Unix socket and remains in GUI memory; it is never stored in SQLite and disappears after replay or restart. After a turn finishes, Xiaoxin evaluates quality evidence before comparing provider Token and duration: completion without verification is never treated as quality success. The menu bar only reports route baselines and measured comparisons; it does not infer a configuration for an unknown future task.

Store and inspect privacy-bounded controlled evaluation samples locally:

```bash
.build/debug/codex-session-guardian-cli --record-routing-evaluation /path/to/sample.json
.build/debug/codex-session-guardian-cli --routing-evaluations --limit 20
.build/debug/codex-session-guardian-cli --routing-outcomes --limit 20
.build/debug/codex-session-guardian-cli --routing-evaluation-summary --baseline-effort max --candidate-effort xhigh
```

This records `sol/medium`, `luna/max`, and `terra/high` as unvalidated habits, not correct routes. The audit separately reports official model roles and effort comparisons, and never applies these habits to another user.

Execution-waste attribution v1 is a shadow ledger: it emits no per-task alerts and takes no automatic action. The menu panel shows aggregate calibration progress. It conservatively records exact repeated reads, exact retries after explicit failures, and measured tool outputs above fixed byte thresholds. Inspect only anonymous observations with evidence:

```bash
.build/debug/codex-session-guardian-cli --execution-waste --only-with-evidence --limit 20
.build/debug/codex-session-guardian-cli --execution-waste-review --only-unlabeled --limit 20
.build/debug/codex-session-guardian-cli --label-execution-waste OBSERVATION_SHA256 --reason repeated_read --verdict confirmed_waste --rationale confirmed_redundant
.build/debug/codex-session-guardian-cli --execution-waste-accuracy
```

Labels are per anonymous observation and reason. Use `confirmed_redundant` with `confirmed_waste`; use `intentional_recheck`, `necessary_recovery`, `necessary_evidence`, or `detector_mismatch` with `justified`; and use `insufficient_context` with `unclear`. Free-form notes are intentionally unsupported. The ledger retains at most 2,000 terminal turns and stores only hashes, counts, event positions, measured output bytes, provider Token categories, quality state, and fixed review labels. It excludes session/turn IDs, paths, prompts, commands, tool arguments, and tool output.

Create an optimized, ad-hoc signed app bundle:

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

The scanner reads local rollout JSONL files incrementally and records only derived usage facts and cursors in SQLite. A separate in-memory tailer follows active sessions at 200 ms cadence for UI activity updates; public-output previews are not persisted. The UI presents one latest turn per session while recent turns remain background evidence for health calibration.

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

The app does not upload session data. Network access is not part of normal monitoring. Live cards read only normalized event types and public assistant output; private reasoning, full tool arguments, raw tool output, stdout, and stderr are never placed into live UI state. Handoff shadow telemetry stores only versioned numeric features, enum reason codes, task/turn identifiers, and exact provider token categories; it excludes titles, working directories, prompts, replies, and handoff bodies, and is bounded to 2,000 decisions and 200 handoffs. The theme import script downloads a pinned public spritesheet only when you run that script manually.

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
