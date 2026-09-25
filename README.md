# Foamy Clock

A clock and calendar for Omarchy Quattro, with a local Evolution Data Server
agenda. The popup keeps the time-first design, month navigation, per-calendar
event dots, and a configurable agenda.

## Install

```sh
omarchy plugin add https://github.com/foamrider/foamy-clock.git --enable
```

Requires Omarchy Quattro. The clock and month grid work without calendar
integration. The agenda additionally needs `python`, `python-gobject`,
`evolution-data-server` and `libical` with their GI typelibs. Select calendars in
GNOME Calendar or another Evolution Data Server client. The calendar shortcut
launches `gnome-calendar` by default; it can be changed in settings.

## Controls

Left-click opens the calendar. Right-click cycles bar formats and saves the
selected format. Middle-click opens Omarchy's timezone picker. In the popup,
use the arrows or mouse wheel to change month, or click a day for its agenda.
Click the header or press `T` to return to today. Arrow keys change month/year;
`W` switches Monday/Sunday week start. Escape closes the popup.

The ghost cog at the top right opens settings. Tab moves through controls;
dropdowns support arrow keys and Enter. Changes are validated and saved through
Omarchy's shell API to the `foamy.clock` widget in `~/.config/omarchy/shell.json`.
Invalid values display an error. Settings are shared by instances on all screens.

## Configuration

| Key | Default | Meaning |
| --- | --- | --- |
| `language` | `system` | Settings and popup text: `system`, `en`, or `nb` |
| `locale` | empty | System date locale; override with a Qt locale such as `en_GB` |
| `format` | `ddd d MMM '' HH:mm` | Horizontal bar format; the clock glyph separates date/time |
| `formatAlt` | `d MMMM 'W'ww yyyy` | Extra preset in the right-click cycle |
| `verticalFormat` | `HH\n—\nmm` | Vertical bar format |
| `verticalFormatAlt` | `dd\nMMM\n'W'ww\n''yy` | Extra vertical preset |
| `weekStartDay` | `locale` | System convention or a lowercase English weekday name |
| `timeFormat` | `24-hour` | Popup and agenda times; also accepts `12-hour` |
| `showSeconds` | `true` | Seconds in the popup; bar seconds follow its format |
| `showTimeZone` | `true` | System timezone label above the popup clock |
| `agendaEnabled` | `true` | Show/query selected Evolution calendars and event dots |
| `agendaRefreshMinutes` | `30` | Refresh interval, 1–1440 minutes |
| `calendarApp` | `gnome-calendar` | Executable name on PATH; no command arguments |
| `showEventLocations` | `true` | Include event locations in rows and tooltips |

Date locale and all four bar formats have preset dropdowns. Choose **Custom**
to enter a locale code or your own format. Format presets show example dates
and times; vertical line breaks appear as dots in the dropdown preview.

Bar formats use Qt date/time tokens, with `ww` added for ISO week numbers. In
the settings fields, use `\n` for a line break. Language and date locale are
independent: choosing English labels does not override your system's date
conventions. Unsupported interface languages use English.

## Agenda and privacy

The helper reads calendars already configured and selected in Evolution Data
Server. It contains no account addresses, calendar IDs, credentials or remote
endpoints. Account configuration and synchronization belong to that service.

Event data is cached locally in `$XDG_CACHE_HOME/foamy-clock/agenda-v1.json`
(or `~/.cache/foamy-clock/agenda-v1.json`). The cache contains event titles,
locations and calendar identifiers: it is private runtime data, not plugin
configuration. Files are atomically written with mode `0600` under a directory
created with mode `0700`, with at most 366 cached dates. Nothing is uploaded by
the plugin and there is no telemetry.

Disabling the agenda hides events and stops new queries and cache reads. A query
already in progress can finish writing its cache; existing cache files are not
deleted. Hiding event locations affects display only, not the local cache.

The helper queries a bounded three-month range and preserves good cached data
when calendars are unavailable. Missing dependencies, no selected calendars,
partial failures, and cached results are handled without exposing account errors.
Changing the calendar app changes only the launch target, not the agenda backend.

## IPC

```sh
omarchy-shell foamy.clock open
omarchy-shell foamy.clock close
omarchy-shell foamy.clock toggle
omarchy-shell foamy.clock settings
omarchy-shell foamy.clock refresh
omarchy-shell foamy.clock cycleFormat
omarchy-shell foamy.clock toggleWeekStart
```

The plugin declares `omarchy.clock` as its clone source, so Omarchy's shell
routing can resolve the standard clock shortcut to the enabled replacement.

## Development

```sh
node tests/model-test.js
node tests/preferences-test.js
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
omarchy plugin validate .
```

After editing linked QML, run `omarchy restart shell`. Check the calendar and
settings in English and Norwegian, keyboard focus and scrolling, persistence,
and agenda enabled/disabled states. Keep screenshots, account data and runtime
caches outside the repository. Tests use synthetic calendar data only.

## License

MIT. Based on Omarchy's clock and popup components; see `LICENSE-OMARCHY`.
The settings controls follow Foamy Media and Weather. Lucide icon attribution
is in `LICENSE-LUCIDE`. Foamy changes are covered by `LICENSE`.
