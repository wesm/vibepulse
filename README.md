# VibePulse

VibePulse is a lightweight macOS menu bar app that shows your Claude Code + Codex token spend, powered by the `ccusage` tools.

## What you get

- Menu bar total for today (combined across Claude Code and Codex)
- Cumulative spend chart for today
- 30‑day daily totals with per‑tool breakdown
- Background refresh on a configurable schedule
- Data maintenance tools to normalize historical imports

## Screenshots

Add screenshots in `docs/screenshots/` and reference them here.

## Requirements

- macOS 13+ (Ventura)
- Node.js (VibePulse runs `npx ccusage@latest` and `npx @ccusage/codex@latest`)
- Claude Code and/or Codex usage logs on disk


## Node.js / npx setup

VibePulse runs outside your shell, so it won't see `nvm`'s PATH unless you tell it where `npx` lives.

Recommended (least friction for menu bar apps):

```bash
brew install node
```

This installs `npx` in `/opt/homebrew/bin/npx` (Apple Silicon) or `/usr/local/bin/npx` (Intel), which VibePulse can auto-detect.

If you use `nvm`:

1. Find your `npx` path:

```bash
command -v npx
```

2. In VibePulse, open **Settings → Dependencies** and paste that path into **npx path**.

If you change your active Node version in `nvm`, update the path in Settings.
## Install

1. Download the latest `.dmg` from GitHub Releases.
2. Drag `VibePulse.app` to your Applications folder.
3. Launch it (macOS Gatekeeper will warn for unsigned builds).

## First run

- VibePulse shows a welcome window with the Node.js requirement and a start‑at‑login toggle.
- You can revisit settings any time from the menu bar.

## Settings

- **Data Sources**: Enable Claude Code and/or Codex.
- **Startup**: Start VibePulse at login (macOS may require approval).
- **Refresh**: Choose how often the app refreshes (5m, 15m, 1h, 4h, 1d).
- **Data Maintenance**: Normalize historical data and rerun import fixes.

## Data & privacy

- All data stays local.
- The database lives at `~/Library/Application Support/VibePulse/vibepulse.sqlite`.
- VibePulse only reads local logs and runs `ccusage`/`@ccusage/codex` via `npx`.

## Local development

```bash
swift run
```

## Build a DMG

```bash
scripts/build_dmg.sh v0.1.0
```

The DMG will be created in `dist/`.

## Troubleshooting

- **No data**: Run `npx ccusage@latest` or `npx @ccusage/codex@latest` in Terminal to verify logs exist.
- **Start at login**: macOS might require approval in System Settings → Login Items.

## License

MIT
