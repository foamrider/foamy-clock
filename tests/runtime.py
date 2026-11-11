#!/usr/bin/env python3
"""Offscreen runtime test of the real widget on Omarchy 4.5.

Uses the foamy-kit preview harness (temp HOME/XDG, no Wayland/Hyprland,
software renderer; 4.5 QML is loaded, never its scripts). The session bus is
pointed at a dead address so the agenda worker cannot reach a live EDS.
Usage: tests/runtime.py [--host 4.5|4.0|both] [--language en|no]

The 4.5 host is FOAMY_HOST_45, else $OMARCHY_TEST_ROOT/shell, else the
installed /usr/share/omarchy/shell (the default --host). 4.0 runs only when
FOAMY_HOST_40 names a 4.0 shell; otherwise --host 4.0/both print SKIP for it.
"""
import argparse
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KIT = Path(os.environ.get("FOAMY_KIT", ROOT.parent / "foamy-kit"))
# Set before the harness reads its hosts.
if not os.environ.get("FOAMY_HOST_45"):
    _root = os.environ.get("OMARCHY_TEST_ROOT")
    os.environ["FOAMY_HOST_45"] = str(Path(_root) / "shell") if _root else "/usr/share/omarchy/shell"
sys.path.insert(0, str(KIT / "preview"))
import harness  # noqa: E402

# The calendar shortcut's host commands: only "foamy-test-calendar" is
# installed, and a launch is recorded in the run's out directory instead.
FAKEBIN = {
    "omarchy-cmd-present": '#!/bin/sh\n[ "$#" -eq 1 ] && [ "$1" = foamy-test-calendar ]\n',
    "omarchy-launch-or-focus": '#!/bin/sh\nprintf "%s\\n" "$*" >>"$FOAMY_OUT/launched"\n',
}


def run(host, language):
    shell = (Path(__file__).parent / "runtime/Runtime.qml").read_text()
    test = harness.Run(host, shell, plugin=ROOT, language=language, prefix="foamy-clock-runtime-", fakebin=FAKEBIN)
    test.env["FOAMY_LANG"] = language
    test.env["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=" + str(test.base / "no-bus")
    test.run(timeout=30)
    result = [line for line in test.log.splitlines() if "FOAMY RESULT" in line]
    print(f"{'PASS' if test.ok else 'FAIL'} {host}/{language} {result[-1].split('RESULT ')[-1] if result else ''}")
    if not test.ok:
        print("\n".join(test.failures() or test.log.splitlines()[-30:]))
    test.cleanup()
    return test.ok


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="4.5", choices=("4.5", "4.0", "both"))
    parser.add_argument("--language", default=None)
    args = parser.parse_args()
    hosts = ["4.5", "4.0"] if args.host == "both" else [args.host]
    if "4.0" in hosts and not os.environ.get("FOAMY_HOST_40"):
        print("SKIP 4.0: set FOAMY_HOST_40 to an Omarchy 4.0 shell to run it")
        hosts.remove("4.0")
    ok = True
    for host in hosts:
        for language in ([args.language] if args.language else (["en", "no"] if host == "4.5" else ["en"])):
            ok &= run(host, language)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
