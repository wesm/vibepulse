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

The local agentsview discovery and per-agent commands will include:

```text
--timezone <TimeZone.autoupdatingCurrent.identifier>
```

Commands will be built from the captured timezone context for each refresh;
their default context will be `TimeZone.autoupdatingCurrent` for direct use.
The server URL query will likewise use that captured timezone identifier.
Existing server query behavior remains unchanged apart from following timezone
changes while the app stays open.

### Safe behavior at a timezone change

VibePulse will remember the timezone identifier used by the last usage refresh.
At the start of each refresh it will capture the current autoupdating timezone
as that refresh's context and compare its identifier with the remembered value.
When they differ, VibePulse will:

1. Remove agent, model, and machine sample snapshots that fall in the current
   local calendar day. These rows contain cumulative totals whose day boundary
   was defined by the old timezone and cannot be converted from their stored
   values alone.
2. Refresh agentsview immediately using the captured explicit timezone.
3. Save the new timezone identifier only after the refresh completes
   successfully.

Rows from prior local days are retained. Daily rollups remain date-keyed source
data and are refreshed from agentsview; display queries will bound their
results to the requested current local window so stale future keys from the
old timezone cannot appear in the chart.

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

All parts of one refresh use its captured timezone context. A timezone change
invalidates only derived current-day samples; the next agentsview response
establishes the new cumulative baseline. A timezone change during an active
refresh is picked up by the following refresh rather than mixing contexts
inside the active one.

## Testing

Add focused regression coverage for:

- A formatter initialized before a process timezone change formats a later date
  with the new timezone.
- Local discovery and per-agent commands include the current timezone, and the
  breakdown fallback preserves that argument.
- Clearing current-day snapshots removes agent, model, and machine samples
  while retaining prior-day samples.
- Daily rollup reads exclude keys after the current local day and still retain
  the requested historical window.

The timezone-change test will restore the process timezone in a `defer` block
so it cannot affect other tests. Existing parsing, refresh, store, chart, and
format checks must remain green.

## Error handling and compatibility

If the timezone identifier is unavailable, Foundation's autoupdating current
timezone remains the fallback used by the existing APIs. A failed agentsview
refresh must not advance the remembered timezone marker; the next refresh will
retry the invalidation and import with the current timezone. No existing
database rows outside the current local day are deleted.
