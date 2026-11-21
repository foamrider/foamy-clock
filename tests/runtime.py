#!/usr/bin/env python3
"""Offscreen runtime test of the real widget on Omarchy 4.5.

Uses the foamy-kit preview harness (temp HOME/XDG, no Wayland/Hyprland,
software renderer; 4.5 QML is loaded, never its scripts). The real helper
runs: its disk cache is seeded with today's month (two events), and a fake
`gi` package makes every Evolution worker fail, whatever the machine has
installed, so a refresh always gives an error or partial month.
Usage: tests/runtime.py [--language en|no]

A run that starts within a minute of midnight can seed "today" for the day
before; the populated step then times out.

The 4.5 host is FOAMY_HOST_45, else $OMARCHY_TEST_ROOT/shell, else the
installed /usr/share/omarchy/shell.
"""

import argparse
from datetime import date, timedelta
import importlib.util
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KIT = Path(os.environ.get("FOAMY_KIT", ROOT.parent / "foamy-kit"))
# Set before the harness reads its hosts.
if not os.environ.get("FOAMY_HOST_45"):
    _root = os.environ.get("OMARCHY_TEST_ROOT")
    os.environ["FOAMY_HOST_45"] = str(Path(_root) / "shell") if _root else "/usr/share/omarchy/shell"
sys.path.insert(0, str(KIT / "preview"))
import harness  # noqa: E402

# The calendar shortcut's host commands: every check is logged, only
# "foamy-test-calendar" is installed, and a launch is recorded in the run's
# out directory instead.
FAKEBIN = {
    "omarchy-cmd-present": (
        '#!/bin/sh\nprintf "%s\\n" "$*" >>"$FOAMY_OUT/present"\n[ "$#" -eq 1 ] && [ "$1" = foamy-test-calendar ]\n'
    ),
    "omarchy-launch-or-focus": '#!/bin/sh\nprintf "%s\\n" "$*" >>"$FOAMY_OUT/launched"\n',
}
# Put first on the helper's PYTHONPATH: the worker's `import gi` finds this.
FAKE_GI = 'def require_version(*_):\n    raise ValueError("no Evolution Data Server in tests")\n'


def helper():
    spec = importlib.util.spec_from_file_location("calendar_events", ROOT / "calendar-events.py")
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def seed_cache(cache_home):
    """Today's month for every week start, as the helper itself stores it.

    The cache records the zone it was cut in. The harness passes this
    process's TZ to the shell, so the helper there reads the same zone.
    """
    calendar = helper()
    today = date.today()
    now = int(time.time())
    first = today.replace(day=1)
    path = Path(cache_home) / "foamy-clock" / f"agenda-v{calendar.CACHE_VERSION}.json"
    for week_start in range(7):  # JS numbering: 0 is Sunday
        start = first - timedelta(days=((first.weekday() + 1) % 7 - week_start) % 7)
        month = calendar.MonthBuilder(start, start + timedelta(days=42))
        common = {"calendar": "Work", "color": "#7aa2f7"}
        # Added timed first, so the all-day-first order comes from the helper's sort.
        # The location carries markup, which the popup must show as text.
        month.add(
            {
                **common,
                "id": "work:standup",
                "title": "Standup",
                "location": "<b>Room 4</b>",
                "allDay": False,
                "start": now - 60,
                "end": now + 7200,
                "startDate": "",
                "endDate": "",
            },
            [today.isoformat()],
        )
        month.add(
            {
                **common,
                "id": "work:offsite",
                "title": "Offsite",
                "location": "",
                "allDay": True,
                "start": 0,
                "end": 0,
                "startDate": today.isoformat(),
                "endDate": (today + timedelta(days=1)).isoformat(),
            },
            [today.isoformat()],
        )
        payload = month.finish()
        payload["selectedCalendars"] = 1
        payload["updatedAt"] = now
        for day in payload["dates"].values():
            day["updatedAt"] = now
        if not calendar.store_view(payload, path):
            raise SystemExit(f"runtime.py: the helper refused the seeded month from {start}")


def run(host, language):
    shell = (Path(__file__).parent / "runtime/Runtime.qml").read_text()
    test = harness.Run(host, shell, plugin=ROOT, language=language, prefix="foamy-clock-runtime-", fakebin=FAKEBIN)
    test.env["FOAMY_LANG"] = language
    fake_gi = test.base / "fakegi" / "gi"
    fake_gi.mkdir(parents=True)
    (fake_gi / "__init__.py").write_text(FAKE_GI)
    test.env["PYTHONPATH"] = str(fake_gi.parent)
    seed_cache(test.env["XDG_CACHE_HOME"])
    # Many steps, each with its own 10 s limit.
    test.run(timeout=90)
    result = [line for line in test.log.splitlines() if "FOAMY RESULT" in line]
    # Every host command the widget runs here has a FAKEBIN stand-in; the
    # harness stubs any other omarchy* command and logs it.
    unfaked = test.host_commands()
    ok = test.ok and not unfaked
    print(f"{'PASS' if ok else 'FAIL'} {host}/{language} {result[-1].split('RESULT ')[-1] if result else ''}")
    if unfaked:
        print("host commands without a fake: " + "; ".join(unfaked))
    if not test.ok:
        print("\n".join(test.failures() or test.log.splitlines()[-30:]))
    test.cleanup()
    return ok


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--language", default=None, choices=("en", "no"))
    args = parser.parse_args()
    ok = True
    for language in [args.language] if args.language else ["en", "no"]:
        ok &= run("4.5", language)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
