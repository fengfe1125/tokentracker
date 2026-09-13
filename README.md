<p align="center">
  <img src="assets/icon_1024.png" width="112" height="112" alt="TokenTracker app icon">
</p>

<h1 align="center">TokenTracker</h1>

<p align="center">
  <strong>English</strong> · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <strong>Know what your AI coding agents cost — without sending their logs anywhere.</strong><br>
  Track tokens, costs, subscription quotas, and agent activity across seven AI coding tools from one native macOS app.
</p>

<p align="center">
  <a href="https://github.com/fengfe1125/tokentracker/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/fengfe1125/tokentracker?display_name=tag&sort=semver&style=flat-square"></a>
  <a href="https://github.com/fengfe1125/tokentracker/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/fengfe1125/tokentracker/total?style=flat-square"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111111?style=flat-square&logo=apple">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white">
  <a href="https://github.com/fengfe1125/tokentracker/stargazers"><img alt="GitHub stars" src="https://img.shields.io/github/stars/fengfe1125/tokentracker?style=flat-square"></a>
</p>

<p align="center">
  <a href="https://github.com/fengfe1125/tokentracker/releases/latest"><strong>Download the latest release</strong></a>
  ·
  <a href="#build-from-source">Build from source</a>
  ·
  <a href="#command-line-tools">CLI</a>
  ·
  <a href="#privacy-and-data">Privacy</a>
</p>

> If TokenTracker helps you understand your AI coding costs, consider giving it a **Star**. It helps other developers who work with multiple agents discover the project.

## v0.3.0 update

Project token breakdowns, data health, session execution timelines, budget/quota risk alerts, local weekly reports, and redacted exports. Costs include estimates and are not subscription bills.

See the [bilingual release notes](docs/v0.3.0-release-notes.md) and [validation notes](docs/v0.3.0-validation.md).

## Why TokenTracker?

Claude Code, Codex, Kimi Code, and other coding agents all record usage differently. Their logs, pricing, and quota information live in separate places. TokenTracker reads those records directly from your Mac and turns them into one clear, native dashboard.

| One overview | Local-first | Beyond token counts |
|---|---|---|
| Compare daily usage, trends, models, sessions, and costs across tools | Usage logs are read and stored locally and are private by default | Inspect subscription quotas, tool calls, Skill activity, and agent-to-tool relationships |

TokenTracker is useful if you:

- use several AI coding CLIs and want to know where your tokens and money go;
- want to compare real usage across models, tools, or individual sessions;
- need visibility into agent tools and Skills without storing prompts or output content;
- prefer a native menu bar utility instead of another browser-based cloud dashboard.

## Supported AI coding tools

| Tool | Tokens / cost | Subscription quota | Agent activity |
|---|:---:|:---:|:---:|
| Claude Code | ✓ | ✓ | ✓ |
| Codex | ✓ | ✓ | ✓ |
| Kimi Code | ✓ | ✓ | ✓ |
| DSH / OpenCode Go | ✓ | ✓ | ✓ |
| Pi | ✓ | — | ✓ |
| opencode | ✓ | — | ✓ |
| Hermes Agent | ✓ | — | ✓ |

> Quota availability depends on the official interfaces and local login state provided by each service. Token and cost tracking does not require a shared cloud account.

## What you get

- **Live menu bar summary** — see today's usage and subscription quotas at a glance.
- **Native analytics** — overview, hand-drawn trends, model rankings, session lists, and separate detail windows.
- **Agent Activity** — tool and Skill summaries, rankings, timelines, and an agent × tool matrix.
- **Traceable costs** — break down tokens and estimated spend by tool, model, date, and session.
- **Resume sessions** — continue a session in Terminal, iTerm2, WezTerm, or Ghostty from its detail view.
- **Built for daily use** — automatic scans, manual refresh, launch at login, in-app updates, and local Codex account switching.

## Quick start

### Install the macOS app

1. Open the [latest release](https://github.com/fengfe1125/tokentracker/releases/latest).
2. Download `TokenTracker-*.dmg` and drag TokenTracker into Applications.
3. Launch the app. It automatically discovers logs from supported tools on your Mac.

TokenTracker requires **macOS 14 Sonoma or later**. Current release builds use an ad-hoc signature. If macOS cannot verify the developer, Control-click the app in Finder and choose **Open**.

On macOS 26 Tahoe, you may also need to allow TokenTracker under System Settings → Menu Bar the first time you use it. See the [menu bar troubleshooting notes](docs/menubar-visibility-plan.md).

### Build from source

You need Xcode Command Line Tools and Swift 6:

```bash
git clone https://github.com/fengfe1125/tokentracker.git
cd tokentracker
./scripts/build_swift_app.sh
open dist/TokenTracker.app
```

To create a local DMG:

```bash
./scripts/release_swift.sh
```

See the release script for Developer ID signing and notarization requirements.

## Privacy and data

TokenTracker has a simple default boundary: **scan locally, store locally, and never upload usage logs.**

- Database: `~/.tokentracker/usage.db`
- Settings: `~/.tokentracker/settings.json`
- Official quota cache: `~/.tokentracker/official_cache.json`
- Local pricing and quota configuration: `prices.json` and `quotas.json`

Network access is used only when querying official subscription quotas or refreshing the login state for the corresponding service. Optional public statistics are disabled by default. When explicitly enabled, the allowlisted payload contains only basic aggregate usage and cost metrics — never project paths, session IDs, titles, prompts, model names, hostnames, or account information.

Agent Activity stores metadata such as tool name, session, timestamp, status, and evidence level. It does not store tool arguments, commands, prompts, or output content. See [Metrics](docs/metrics.md) for calculation details and [Migrations](docs/migrations.md) for database compatibility and recovery.

## Command-line tools

The native Swift CLI shares its database with the app:

```bash
swift build -c release --package-path swift
swift/.build/release/tt-swift detect
swift/.build/release/tt-swift scan --full
swift/.build/release/tt-swift stats --range week
swift/.build/release/tt-swift activity --range week --group tool --confidence all
swift/.build/release/tt-swift quotas
```

The Python CLI remains available during the transition for full argument compatibility and Swift differential testing:

```bash
./tt detect
./tt scan --full
./tt stats --range week
./tt activity --range week --group tool --confidence all
./tt quotas
```

## Data sources

| Tool | Default location | Usage source |
|---|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl` | assistant usage |
| Codex | `~/.codex/sessions/**/*.jsonl`, `~/.codex/logs_*.sqlite` | token_count and turn telemetry |
| Kimi Code | `~/.kimi-code/server/events/session_*.jsonl` | turn.step.completed |
| DSH | `~/.dsh/sessions/**/session.jsonl.zstd` | usage events |
| Pi | `~/.pi/agent/sessions/**/*.jsonl` | message usage |
| opencode | `~/.local/share/opencode/opencode.db` | cumulative session usage |
| Hermes Agent | `~/.hermes/**/*.db` | session_model_usage |

Environment variables can override the data source paths. See the individual scanners and `ScanRoots` for the complete list.

## Project structure

```text
swift/
  Sources/TokenTrackerCore/       Scanning, storage, pricing, quotas, resume, and updates
  Sources/TokenTrackerApp/        Native SwiftUI / AppKit macOS app
  Sources/tt-swift/               Native CLI
  Tests/                          Swift tests
tokentracker/                      Transitional Python CLI and differential oracle
tests/differential/               Cross-implementation fixtures and frozen baselines
assets/                            App icon sources and ICNS
scripts/                           Build, release, and icon verification
```

See the [SwiftUI migration notes](docs/swiftui-migration-plan.md) for module mapping and the [icon documentation](docs/icon-design.md) for asset provenance and offline verification.

## Development and testing

```bash
python3 -m unittest discover -s tests -v
swift test --package-path swift
python3 scripts/check_icon.py
```

Swift differential tests use `tests/differential/expected_python.json` as a frozen baseline. The system `zstd` binary is required when generating the synthetic fixtures for the first time.

---

<p align="center">
  Built for developers who want the benefits of AI coding agents without losing sight of usage, cost, or privacy.<br>
  <a href="https://github.com/fengfe1125/tokentracker/stargazers"><strong>Useful? Give TokenTracker a Star ★</strong></a>
</p>
