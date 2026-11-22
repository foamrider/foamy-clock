#!/usr/bin/env python3
"""Offscreen runtime test of the real widget on Omarchy 4.5.

Uses the foamy-kit preview harness (temp HOME/XDG, no Wayland/Hyprland,
software renderer; 4.5 QML is loaded, never its scripts). The real helper
runs: its disk cache is seeded with today's month (two events today, one
with a long title two days away), and a fake `gi` package makes every
Evolution worker fail, whatever the machine has installed, so a refresh
always gives an error or partial month.
A first, shorter run (runtime/Teardown.qml) quits the shell during a month
refresh whose worker hangs, and checks that the bridge and worker end too.
A second one kills the shell in the same state, as a crash would, and checks
that the real `timeout` wrapper, the bridge and the worker end.
Usage: tests/runtime.py [--language en|no]

The seeded events are on the day this process sees and the shell reads its
own clock, so no run starts when it could cross local midnight: it waits.

The 4.5 host is FOAMY_HOST_45, else $OMARCHY_TEST_ROOT/shell, else the
installed /usr/share/omarchy/shell.
"""

import argparse
from datetime import date, datetime, timedelta
import importlib.util
import os
import signal
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
# For the teardown run: a worker that hangs (bounded) after it has written
# its pid and its bridge's pid to $FOAMY_OUT/worker.
HANGING_GI = """import os, time
def require_version(*_):
    path = os.environ["FOAMY_OUT"] + "/worker"
    with open(path + ".tmp", "w") as handle:
        handle.write(f"{os.getpid()} {os.getppid()}\\n")
    os.replace(path + ".tmp", path)
    time.sleep(50)
"""
# Stands in for coreutils timeout when Quickshell's kill lands before timeout
# forwards it: the command stays in the wrapper's process group, and a
# signal ends only the wrapper.
SILENT_TIMEOUT = """#!/usr/bin/env python3
import os, subprocess, sys
os.setpgid(0, 0)
sys.exit(subprocess.call(sys.argv[2:]))
"""


def helper():
    spec = importlib.util.spec_from_file_location("calendar_events", ROOT / "calendar-events.py")
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def long_event_day(today):
    """The day of the long event: two days from today, in today's month,
    and not the day after (or before) today, which the scene shows empty."""
    return today - timedelta(days=2) if today.day > 2 else today + timedelta(days=2)


def seed_cache(cache_home):
    """Today's month for every week start, as the helper itself stores it.

    The cache records the zone it was cut in. The harness passes this
    process's TZ to the shell, so the helper there reads the same zone.
    """
    calendar = helper()
    today = date.today()
    now = int(time.time())
    first = today.replace(day=1)
    long_day = long_event_day(today)
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
        # A long title, and a meeting link (one word, no spaces) as the
        # location: the event's tooltip must wrap them in its capped box.
        month.add(
            {
                **common,
                "id": "work:planning",
                "title": "Quarterly planning with the platform, design and support teams: "
                "the roadmap for next year, the budget, hiring and a look back at the autumn releases",
                "location": "https://meet.example.com/l/meetup-join/19%3ameeting_Zm9hbXktY2xvY2stbG9uZy1saW5r"
                "%40thread.v2/0?context=foamy-clock",
                "allDay": True,
                "start": 0,
                "end": 0,
                "startDate": long_day.isoformat(),
                "endDate": (long_day + timedelta(days=1)).isoformat(),
            },
            [long_day.isoformat()],
        )
        payload = month.finish()
        payload["selectedCalendars"] = 1
        payload["updatedAt"] = now
        for day in payload["dates"].values():
            day["updatedAt"] = now
        if not calendar.store_view(payload, path):
            raise SystemExit(f"runtime.py: the helper refused the seeded month from {start}")


def wait_clear_of_midnight(now=None):
    """Sleep past local midnight when a run that starts now could cross it.

    A run is limited to 90 s. One that crossed midnight would seed its events
    on the day before the day the shell shows, and fail on correct code.
    Returns the seconds it waited.
    """
    now = now or datetime.now()
    midnight = datetime.combine(now.date() + timedelta(days=1), datetime.min.time())
    left = (midnight - now).total_seconds()
    if left >= 120:
        return 0
    print(f"runtime.py: waiting {left:.0f} s for midnight to pass, so that the seeded day stays today", flush=True)
    time.sleep(left + 1)
    return left + 1


def run(host, language):
    wait_clear_of_midnight()
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


def alive(pid):
    """True while `pid` is a running (not zombie) helper process."""
    try:
        stat = Path(f"/proc/{pid}/stat").read_text()
        cmdline = Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError:
        return False
    return stat.rsplit(")", 1)[1].split()[0] != "Z" and b"calendar-events.py" in cmdline


def teardown(host):
    """The shell quits during a month refresh: its bridge and worker go too."""
    shell = (Path(__file__).parent / "runtime/Teardown.qml").read_text()
    fakebin = {**FAKEBIN, "timeout": SILENT_TIMEOUT}
    test = harness.Run(host, shell, plugin=ROOT, prefix="foamy-clock-teardown-", fakebin=fakebin)
    fake_gi = test.base / "fakegi" / "gi"
    fake_gi.mkdir(parents=True)
    (fake_gi / "__init__.py").write_text(HANGING_GI)
    test.env["PYTHONPATH"] = str(fake_gi.parent)
    test.run(timeout=30)
    record = Path(test.env["FOAMY_OUT"]) / "worker"
    pids = [int(pid) for pid in record.read_text().split()] if record.exists() else []
    left = []
    if pids:
        # The bridge and worker end shortly after their wrapper: the bridge
        # gets its parent-death signal, and its handler kills the worker.
        harness.wait_for(lambda: not any(alive(pid) for pid in pids), timeout=10)
        left = [pid for pid in pids if alive(pid)]
    for pid in left:
        os.kill(pid, signal.SIGKILL)
    ok = test.ok and len(pids) == 2 and not left
    print(f"{'PASS' if ok else 'FAIL'} {host} teardown: worker and bridge {pids}, left running {left}")
    if not test.ok:
        print("\n".join(test.failures() or test.log.splitlines()[-30:]))
    test.cleanup()
    return ok


def crash(host):
    """The shell dies during a month refresh without stopping its helper
    (SIGKILL, as a crash): the real wrapper, the bridge and the worker go too."""
    shell = (Path(__file__).parent / "runtime/Teardown.qml").read_text()
    test = harness.Run(host, shell, plugin=ROOT, prefix="foamy-clock-crash-", fakebin=FAKEBIN)
    fake_gi = test.base / "fakegi" / "gi"
    fake_gi.mkdir(parents=True)
    (fake_gi / "__init__.py").write_text(HANGING_GI)
    test.env["PYTHONPATH"] = str(fake_gi.parent)
    test.env["FOAMY_TEARDOWN"] = "crash"
    record = Path(test.env["FOAMY_OUT"]) / "worker"
    pids = []
    left = []
    test.start()
    try:
        if test.wait_for_log("FOAMY WORKER RUNNING", timeout=30) and record.exists():
            pids = [int(pid) for pid in record.read_text().split()]
            # The bridge's parent is the `timeout` wrapper.
            pids.append(int(Path(f"/proc/{pids[1]}/stat").read_text().rsplit(")", 1)[1].split()[1]))
            # Only the shell itself: `timeout` keeps the helpers in a process
            # group of their own, which the harness's group kill never reaches.
            os.kill(test.process.pid, signal.SIGKILL)
            test.process.wait()
            harness.wait_for(lambda: not any(alive(pid) for pid in pids), timeout=10)
            left = [pid for pid in pids if alive(pid)]
    finally:
        for pid in left:
            os.kill(pid, signal.SIGKILL)
        test.stop()
    ok = len(pids) == 3 and not left and not test.failures()
    print(f"{'PASS' if ok else 'FAIL'} {host} crash: worker, bridge and wrapper {pids}, left running {left}")
    if not ok:
        print("\n".join(test.failures() or test.log.splitlines()[-30:]))
    test.cleanup()
    return ok


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--language", default=None, choices=("en", "no"))
    args = parser.parse_args()
    ok = teardown("4.5")
    ok &= crash("4.5")
    for language in [args.language] if args.language else ["en", "no"]:
        ok &= run("4.5", language)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
