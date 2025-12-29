# VibePulse

A tiny macOS menu bar app that tracks Claude Code + Codex token spend using the `ccusage` tools and visualizes daily/hourly usage.

## Features

- Menu bar total for today (Claude Code + Codex)
- Sparkline-style hourly chart for the current day
- 30-day daily totals view with per-tool breakdown
- Automatic snapshot collection every 5–15 minutes
- Built-in maintenance to normalize/import historical data

## Requirements

- macOS 13+ (Ventura)
- Node.js (for `npx ccusage@latest` and `npx @ccusage/codex@latest`)
- Claude Code and/or Codex usage logs on disk

## Install (Release)

1. Download the latest `.dmg` from GitHub Releases.
2. Drag `VibePulse.app` into your Applications folder.
3. Launch it (macOS Gatekeeper will warn for unsigned builds).

## Local Development

```bash
swift run
```

## Build a DMG

```bash
scripts/build_dmg.sh v0.1.0
```

The DMG will land in `dist/`.

## Notes

- The app stores snapshots in `~/Library/Application Support/VibePulse/vibepulse.sqlite`.
- Daily totals are read from `ccusage` JSON output; hourly totals are inferred from stored snapshots.
- Data maintenance runs automatically once per day by default. You can switch to manual mode in Settings.

## License

MIT
