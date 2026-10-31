#!/usr/bin/env python3
"""Offscreen runtime test of the real widget on 4.0.6 and 4.5-rc2 hosts.

Uses the foamy-kit preview harness (temp HOME/XDG, no Wayland/Hyprland,
software renderer; 4.5 QML is loaded, never its scripts). The session bus is
pointed at a dead address so the agenda worker cannot reach a live EDS.
Usage: tests/runtime.py [--host 4.0|4.5|both] [--language en|no]
"""
import argparse
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KIT = Path(os.environ.get("FOAMY_KIT", ROOT.parent / "foamy-kit"))
sys.path.insert(0, str(KIT / "preview"))
import harness  # noqa: E402


def run(host, language):
    shell = (Path(__file__).parent / "runtime/Runtime.qml").read_text()
    test = harness.Run(host, shell, plugin=ROOT, language=language, prefix="foamy-clock-runtime-")
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
    parser.add_argument("--host", default="both", choices=("4.0", "4.5", "both"))
    parser.add_argument("--language", default=None)
    args = parser.parse_args()
    hosts = ["4.0", "4.5"] if args.host == "both" else [args.host]
    ok = True
    for host in hosts:
        for language in ([args.language] if args.language else (["en", "no"] if host == "4.5" else ["en"])):
            ok &= run(host, language)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
