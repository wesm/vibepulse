# Timezone Changes Design

## Problem

VibePulse mixes two timezone contexts after the macOS system timezone changes.
The date formatters in `DateHelper` retain the timezone that existed when they
were first created, while the agentsview server request and the local
agentsview process can use the new timezone. Today totals and chart points can
then combine cumulative snapshots from different calendar days. The result is
the misleading reset and jump visible in the Today graph.

The local agentsview CLI also accepts an explicit `--timezone` flag. VibePulse
currently omits that flag, so the source and the app do not share an explicit
calendar context.

## Goals

- Make VibePulse follow the current macOS timezone without requiring a restart.
- Make local and server-backed agentsview requests use that same timezone.
- Never show cumulative Today samples collected under different local-day
  definitions as one continuous graph.
- Keep historical daily totals and prior-day snapshots available.
- Keep the change local to timezone handling and usage refresh behavior.

## Non-goals

- Reconstructing old per-sample cumulative totals for a new timezone. Those
  totals are derived snapshots from agentsview, not raw usage events.
- Changing the agentsview report window or its pricing and parsing rules.
- Introducing a database schema migration or storing a timezone on every row.

## Design

### One live timezone source

`DateHelper` will use `TimeZone.autoupdatingCurrent` for its canonical and
textual formatters. Calendar operations used to find today and prior dates
will use `Calendar.autoupdatingCurrent`. Other usage-specific calendar helpers
will use the same autoupdating calendar.

Each refresh will also create one explicit usage-date context containing its
captured timezone, calendar, sample time, today key, start of today, and start
of the next local day. DateHelper will provide the explicit-timezone operations
needed by this context in addition to its autoupdating defaults.

The local agentsview discovery and per-agent commands will include:

```text
--timezone <captured IANA timezone identifier>
```

Commands will be built from the captured timezone context for each refresh;
their default context will be `TimeZone.autoupdatingCurrent` for direct use.
The server URL query will likewise use that captured timezone identifier.
Existing server query behavior remains unchanged apart from following timezone
changes while the app stays open.

The minimum supported agentsview version is v0.40.0, whose `usage daily`
command accepts `--timezone`. VibePulse will not retry a rejected timezone
flag without the flag. An unsupported-flag error will instead report that an
agentsview v0.40.0-or-newer installation is required for timezone-aware usage.
The existing breakdown fallback will continue to remove only `--breakdown`, so
the timezone argument remains present on the fallback command.

### Safe behavior at a timezone change

VibePulse will remember the timezone identifier used by the last usage refresh.
At the start of each refresh it will capture the current autoupdating timezone
as that refresh's context and compare its identifier with the remembered value.
When they differ, VibePulse will:

1. Remove agent, model, and machine sample snapshots whose `recorded_at` is in
   the half-open interval `[startOfToday, startOfNextDay)`, using the new
   context. The deletion is timestamp-based because Today queries also select
   by `recorded_at`; a `date_key` predicate would miss rows written under the
   old timezone whose keys now name a different calendar day.
2. Refresh agentsview immediately using the captured explicit timezone.
3. Save the new timezone identifier only after the refresh completes
   successfully.

Rows from prior local days are retained. Daily rollups remain date-keyed source
data and are refreshed from agentsview; display queries will bound their
results to both the lower and upper date keys of the requested current local
window, so stale future keys from the old timezone cannot appear in the chart.

Sample delta baselines will use the same `recorded_at` day interval rather than
looking up prior totals by `date_key`. This prevents an old timezone's key from
seeding a new timezone's cumulative baseline. The stored `date_key` remains for
existing schema compatibility and inspection, but it is not the authority for
current-day sample selection or delta calculation.

The next scheduled refresh still performs the comparison, so the behavior is
correct even if the system timezone notification is missed. A system timezone
change notification will also trigger a refresh when the app is running.

### Data flow

```text
macOS timezone
      |
      v
autoupdating timezone/calendar
      |
      +--> DateHelper keys and day boundaries
      +--> agentsview --timezone argument / server query
      +--> timezone-change snapshot invalidation
      +--> chart window and daily point filtering
```

All source requests, date keys, sample writes, and day-boundary queries in one
refresh use its captured timezone context. A timezone change invalidates only
derived current-day samples; the next agentsview response establishes the new
cumulative baseline. If the system timezone changes during an active refresh,
the refresh still completes under its captured context, does not publish that
context as current, and queues a follow-up refresh before reloading the charts.

## Testing

Add focused regression coverage for:

- A formatter initialized before a process timezone change formats a later date
  with the new timezone.
- Local discovery and per-agent commands include the current timezone, and the
  breakdown fallback preserves that argument.
- An unsupported `--timezone` error becomes an actionable dependency error and
  is never retried without the flag.
- Clearing current-day snapshots by `recorded_at` removes agent, model, and
  machine samples with old or new timezone keys while retaining prior-day
  samples.
- Sample delta baselines use recorded-time day ranges and do not use stale
  date-key values.
- Daily rollup reads apply both lower and upper date bounds and still retain
  the requested historical window.

The timezone-change test will restore the process timezone in a `defer` block
so it cannot affect other tests; the CI test command runs the suite in one
process. Existing parsing, refresh, store, chart, and format checks must remain
green.

## Error handling and compatibility

Foundation always supplies the autoupdating current timezone context. If the
agentsview command rejects `--timezone`, VibePulse reports the minimum
dependency version and does not issue an unscoped retry. A failed agentsview
refresh must not advance the remembered timezone marker; the next refresh will
retry the invalidation and import with the current timezone. No existing
database rows outside the current local day are deleted.
