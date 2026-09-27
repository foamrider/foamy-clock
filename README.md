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
