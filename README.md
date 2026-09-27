# Foamy Clock

A clock, month calendar, and calendar agenda.

![Foamy Clock screenshot](preview.png)

## Install

Requires Omarchy Quattro and Python 3. Agenda access also uses
`python-gobject` and Evolution Data Server (`evolution-data-server`).

For events, install GNOME Calendar (`gnome-calendar`) and select your calendars.

```sh
omarchy plugin add https://github.com/foamrider/foamy-clock.git --enable
```

## Use

- Left-click the clock to open the calendar. Select a day to see its events.
- Use the arrows to change month; click the header to return to today.
- Open the cog to change language, time format, and agenda settings.
- Right-click the bar clock to cycle formats. Middle-click opens the timezone picker.

The calendar shortcut opens GNOME Calendar by default; change it in settings.

## Agenda behavior

The agenda preloads event summaries for all 42 dates in the visible month grid
with one range query per selected calendar. Event dots and daily agendas use the
same data. Selecting a loaded day, including an empty day, is immediate and does
not query Evolution or interrupt a background refresh.

While the agenda is enabled, the current month and the next three calendar months
are refreshed automatically, including while the popup is closed. The visible
month loads first; background months load one at a time and yield when you need
another month or press Refresh. Fresh cached months are reused. Background work
uses the configured agenda refresh interval, with due times checked each minute;
failed attempts wait for that interval before retrying.

Month views are cached across shell restarts; there is no month-cache setting.
Cached events remain visible while stale data refreshes in the background. The
refresh button always requests fresh data for the visible month. The three-month
horizon rolls forward with the current date and uses your configured week start.

The footer shows **Partial update · open calendar** when the selected day's
refresh is incomplete. Click it, or the Calendar button, to open the full calendar
app. Complete cached dates remain available when their refresh fails, while
successful dates update normally. Empty partial results do not mean that the day
has no events. Incomplete dates also have a warning in their calendar tooltip.

To protect the desktop shell, each month holds at most 1,000 event summaries and
2 MiB of encoded data, with at most 100 events per date. An occurrence spanning
several dates is stored once and referenced from each date. Event titles,
locations, and calendar names have fixed length limits. The panel renders up to
five calendar markers per date and only creates visible agenda rows.

Queries allow 32 selected calendars, two active clients, and 2,048 occurrence
callbacks per source. Worker processes retain the 512 MiB virtual-memory limit
and 45-second deadline. The bridge bounds the full month before parsing it, then
sends at most twelve bounded messages (256 KiB each) to the shell. The shell also
checks the assembled month and replaces its previous view only after receiving
the complete transaction. Resource limits or source failures produce an explicit
incomplete state; displayed partial counts say how many events are shown.
Background prefetch uses the same worker and limits, writes to the disk cache,
and sends no event data to the shell. It does not run alongside a foreground
calendar worker or multiply the shell's in-memory month views.

The private disk cache is limited to 8 MiB and eight recently used views; older
views are evicted automatically. Retained months remain available offline. The
first visit to an uncached month needs a refresh, and offline coverage depends
on which views remain in the cache. The three months ahead become available as
background loading completes; source failures and the fixed cache/event limits
can prevent complete coverage.

The cache lives at `$XDG_CACHE_HOME/foamy-clock/agenda-v3.json` (default:
`~/.cache/foamy-clock/agenda-v3.json`). Older `agenda-v1.json` and `agenda-v2.json`
caches are ignored and can be removed. Calendar accounts and events remain
managed by Evolution.

## Remove

```sh
omarchy plugin remove foamy.clock
```

When removing an enabled replacement, Omarchy restores `omarchy.clock`.
Calendar accounts, events, GNOME Calendar, and the agenda cache remain on disk.

Omarchy manages the plugin entry in `shell.json`. Packages and data outside
the plugin directory are retained unless you remove them separately.

## License

Licensed under [MIT](LICENSE), with [Omarchy](LICENSE-OMARCHY) and
[Lucide](LICENSE-LUCIDE) notices.

Provided **as is**, without warranty or guaranteed support. Use at your own risk.
