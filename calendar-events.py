#!/usr/bin/env python3
"""Bounded Evolution agenda worker, cache and JSON-lines bridge for the shell."""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, time, timedelta
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import selectors
import signal
import subprocess
import sys
import tempfile
import time as monotonic_time
from typing import Any
from zoneinfo import ZoneInfo

DEFAULT_COLOR = ""
UNTITLED_EVENT = "Untitled event"
CACHE_VERSION = 3
MAX_QUERY_DAYS = 42
MAX_EVENTS = 100
MAX_SOURCES = 32
MAX_OCCURRENCES = 2048
MAX_DOTS = 5
MAX_RESPONSE_BYTES = 256 * 1024
MAX_MONTH_EVENTS = 1000
MAX_MONTH_BYTES = 2 * 1024 * 1024
MAX_CACHE_BYTES = 8 * 1024 * 1024
MAX_CACHE_ENTRIES = 8
WORKER_MEMORY_BYTES = 512 * 1024 * 1024
WORKER_SECONDS = 45
TEXT_LIMITS = {"title": 256, "location": 128, "calendar": 80}
TEXT_CONTROLS = str.maketrans({chr(code): " " for code in range(32)})


def normalize_color(value: object) -> str:
    text = str(value or "")[:64].strip()
    if re.fullmatch(r"#[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?", text):
        return text.lower()
    match = re.fullmatch(r"rgb\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*\)", text)
    return "#" + "".join(f"{min(255, int(c)):02x}" for c in match.groups()) if match else DEFAULT_COLOR


def clean_text(value: object, fallback: str = "", limit: int = 256) -> str:
    raw = str(value or "")
    # Slice before split: whitespace-heavy remote fields must not allocate a list
    # proportional to their original length. GI allocations have a process cap.
    # Control bytes would otherwise expand to six-byte JSON escapes and can
    # also render invisibly. Normalize them within the already bounded slice.
    text = " ".join(raw[:limit].translate(TEXT_CONTROLS).split())
    if len(raw) > limit:
        text = text[:limit - 1] + "…"
    return text or fallback


def stable_id(value: str) -> str:
    digest = hashlib.sha256()
    for offset in range(0, len(value), 4096):
        digest.update(value[offset:offset + 4096].encode("utf-8"))
    return digest.hexdigest()[:32]


def ical_date(value: Any) -> date:
    return date(value.get_year(), value.get_month(), value.get_day())


def unix_timestamp(value: Any, fallback_timezone: Any) -> int:
    return int(value.as_timet_with_zone(value.get_timezone() or fallback_timezone))


def local_timezone() -> Any:
    if os.environ.get("TZ"):
        return ZoneInfo(os.environ["TZ"].removeprefix(":"))
    with open("/etc/localtime", "rb") as handle:
        return ZoneInfo.from_file(handle, key=str(Path("/etc/localtime").resolve()))


def overlaps(event: dict[str, Any], day: date, timezone: Any) -> bool:
    if event["allDay"]:
        return event["startDate"] <= day.isoformat() < event["endDate"]
    start = datetime.combine(day, time.min, timezone).timestamp()
    end = datetime.combine(day + timedelta(days=1), time.min, timezone).timestamp()
    return event["start"] < end and max(event["start"] + 1, event["end"]) > start


def event_order(event: dict[str, Any]) -> tuple:
    return (not event["allDay"], event["startDate"] if event["allDay"] else event["start"], event["title"].casefold(), event["id"])


def base_payload(kind: str, start: date, end: date, state: str = "missing") -> dict[str, Any]:
    payload = {"kind": kind, "date": start.isoformat(), "rangeEnd": end.isoformat(),
               "state": state, "events": [], "dates": {}, "selectedCalendars": 0,
               "updatedAt": 0, "cached": state == "missing", "complete": state == "ok"}
    if kind == "month":
        payload["dates"] = {
            (start + timedelta(days=i)).isoformat(): {
                "events": [], "state": state, "complete": state == "ok",
                "updatedAt": 0, "cached": state == "missing",
            } for i in range((end - start).days)
        }
    return payload


class MonthBuilder:
    """Store each occurrence once, with bounded per-day references and bytes."""

    def __init__(self, start: date, end: date):
        self.payload = base_payload("month", start, end, "ok")
        self.indices: dict[bytes, int] = {}
        self.event_bytes = 0

    def incomplete(self, keys, state="partial"):
        for key in keys:
            self.payload["dates"][key].update(state=state, complete=False)

    def add(self, event, keys, shortened=False):
        available = []
        encoded = encode(event)
        # A partial refresh may retain an older revision on one date while
        # another date has fresh fields for the same spanning occurrence.
        identity = hashlib.sha256(encoded).digest()
        index = self.indices.get(identity)
        for key in keys:
            day = self.payload["dates"][key]
            if index is not None and index in day["events"]:
                continue
            if len(day["events"]) >= MAX_EVENTS:
                self.incomplete([key])
            else:
                available.append(key)
        if not available:
            return
        if index is None:
            size = len(encoded) + 1
            # Reserve space for all 42 date records and their index arrays.
            if (len(self.indices) >= MAX_MONTH_EVENTS
                    or self.event_bytes + size > MAX_MONTH_BYTES - 65536):
                self.incomplete(available)
                return
            index = len(self.payload["events"])
            self.indices[identity] = index
            self.payload["events"].append(event)
            self.event_bytes += size
        for key in available:
            self.payload["dates"][key]["events"].append(index)
        if shortened:
            self.incomplete(keys)

    def finish(self):
        events = self.payload["events"]
        for day in self.payload["dates"].values():
            day["events"].sort(key=lambda index: event_order(events[index]))
        states = [day["state"] for day in self.payload["dates"].values()]
        self.payload["state"] = "ok" if all(state == "ok" for state in states) else "error" if all(state == "error" for state in states) else "partial"
        self.payload["complete"] = all(day["complete"] for day in self.payload["dates"].values())
        return self.payload


def fetch_source_events(source: Any, source_name: str, source_color: str,
                        range_start: datetime, range_end: datetime,
                        ecal: Any, ical: Any, kind: str = "day") -> tuple[Any, str]:
    events: list[dict[str, Any]] = []
    month = MonthBuilder(range_start.date(), range_end.date()) if kind == "month" else None
    limited = False
    visited = 0
    callback_failed = False
    try:
        client = ecal.Client.connect_sync(source, ecal.ClientSourceType.EVENTS, 2, None)
        source_id = stable_id(source.get_uid() or "")
        days = [range_start.date() + timedelta(days=i)
                for i in range((range_end.date() - range_start.date()).days)]

        def collect_instance(component, instance_start, instance_end, _data, _cancellable):
            nonlocal visited, limited
            visited += 1
            if visited > MAX_OCCURRENCES:
                limited = True
                if month:
                    month.incomplete(month.payload["dates"])
                return False
            if component.get_status() == ical.PropertyStatus.CANCELLED:
                return True
            if instance_start.is_date():
                start = ical_date(instance_start)
                end = max(start + timedelta(days=1), ical_date(instance_end))
                event = {"allDay": True, "start": 0, "end": 0,
                         "startDate": start.isoformat(), "endDate": end.isoformat()}
            else:
                start = unix_timestamp(instance_start, client.get_default_timezone())
                end = max(start, unix_timestamp(instance_end, client.get_default_timezone()))
                event = {"allDay": False, "start": start, "end": end,
                         "startDate": "", "endDate": ""}
            matching = [day.isoformat() for day in days if overlaps(event, day, range_start.tzinfo)]
            if not matching:
                return True
            if not month and len(events) >= MAX_EVENTS:
                limited = True
                return False
            raw_title = component.get_summary() or ""
            raw_location = component.get_location() or ""
            shortened = (len(raw_title) > TEXT_LIMITS["title"]
                         or len(raw_location) > TEXT_LIMITS["location"]
                         or len(source_name) > TEXT_LIMITS["calendar"])
            event.update({"id": source_id + ":" + stable_id(component.get_uid() or "") + ":" + str(start),
                          "title": clean_text(raw_title, UNTITLED_EVENT, TEXT_LIMITS["title"]),
                          "location": clean_text(raw_location, limit=TEXT_LIMITS["location"]),
                          "calendar": clean_text(source_name, "Calendar", TEXT_LIMITS["calendar"]),
                          "color": source_color})
            if month:
                month.add(event, matching, shortened)
            else:
                limited |= shortened
                events.append(event)
            return True

        def add_instance(*args):
            nonlocal callback_failed
            try:
                return collect_instance(*args)
            except Exception:
                # GI otherwise logs callback exceptions and may return success.
                callback_failed = True
                return False

        client.generate_instances_sync(int(range_start.timestamp()), int(range_end.timestamp()), None, add_instance, None)
    except Exception:
        callback_failed = True
    if month:
        if callback_failed:
            month.incomplete(month.payload["dates"])
        return month.finish(), "unavailable" if callback_failed else ""
    return events, "unavailable" if callback_failed else "limited" if limited else ""


def load_view(kind: str, start: date, end: date) -> dict[str, Any]:
    if not 0 < (end - start).days <= (1 if kind == "day" else MAX_QUERY_DAYS):
        raise ValueError("invalid calendar range")
    import gi
    gi.require_version("ECal", "2.0")
    gi.require_version("EDataServer", "1.2")
    gi.require_version("ICalGLib", "4.0")
    from gi.repository import ECal, EDataServer, ICalGLib

    zone = local_timezone()
    start_time, end_time = (datetime.combine(day, time.min, zone) for day in (start, end))
    registry = EDataServer.SourceRegistry.new_sync(None)
    sources = []
    limited = False
    for source in registry.list_sources(EDataServer.SOURCE_EXTENSION_CALENDAR):
        extension = source.get_extension(EDataServer.SOURCE_EXTENSION_CALENDAR)
        if source.get_enabled() and extension.get_selected():
            if len(sources) == MAX_SOURCES:
                limited = True
                break
            name = source.get_display_name() or "Calendar"
            limited |= kind == "day" and len(name) > TEXT_LIMITS["calendar"]
            sources.append((
                source,
                name[:TEXT_LIMITS["calendar"] + 1],
                normalize_color(extension.get_color()),
            ))
    payload = base_payload(kind, start, end, "ok")
    payload["selectedCalendars"] = len(sources)
    payload["updatedAt"] = int(datetime.now().timestamp())
    month = MonthBuilder(start, end) if kind == "month" else None
    failures = 0
    # Two clients and two futures at a time keep both EDS work and retained
    # results bounded. Process limits also cover allocations inside GI/EDS.
    with ThreadPoolExecutor(max_workers=2) as pool:
        for offset in range(0, len(sources), 2):
            futures = [pool.submit(fetch_source_events, *source, start_time, end_time, ECal, ICalGLib, kind)
                       for source in sources[offset:offset + 2]]
            for future in futures:
                result, error = future.result()
                failures += error == "unavailable"
                limited |= bool(error)
                if kind == "day":
                    payload["events"].extend(result)
                    payload["events"].sort(key=event_order)
                    limited |= len(payload["events"]) > MAX_EVENTS
                    del payload["events"][MAX_EVENTS:]
                else:
                    for key, day in result["dates"].items():
                        for index in day["events"]:
                            month.add(result["events"][index], [key])
                        if not day["complete"]:
                            month.incomplete([key])
    if month:
        if limited:
            month.incomplete(month.payload["dates"], "error" if sources and failures == len(sources) else "partial")
        for day in month.payload["dates"].values():
            day["updatedAt"] = payload["updatedAt"]
        month.payload["selectedCalendars"] = payload["selectedCalendars"]
        month.payload["updatedAt"] = payload["updatedAt"]
        return month.finish()
    payload["state"] = "error" if sources and failures == len(sources) else "partial" if limited else "ok"
    payload["complete"] = payload["state"] == "ok"
    return payload


def encode(payload: Any) -> bytes:
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")


def valid_payload(payload: Any) -> bool:
    """Validate disk/worker data before it can become a shell model."""
    if not isinstance(payload, dict) or set(payload) != {"kind", "date", "rangeEnd", "state", "events", "dates", "selectedCalendars", "updatedAt", "cached", "complete"}:
        return False
    try:
        kind = payload["kind"]
        start, end = date.fromisoformat(payload["date"]), date.fromisoformat(payload["rangeEnd"])
        if kind not in ("day", "month") or not 0 < (end - start).days <= (1 if kind == "day" else MAX_QUERY_DAYS):
            return False
        if payload["state"] not in ("ok", "partial", "error", "missing") or type(payload["cached"]) is not bool or type(payload["complete"]) is not bool:
            return False
        if type(payload["selectedCalendars"]) is not int or not 0 <= payload["selectedCalendars"] <= MAX_SOURCES:
            return False
        if type(payload["updatedAt"]) is not int or not 0 <= payload["updatedAt"] <= 253402300799:
            return False
        events, dates = payload["events"], payload["dates"]
        if not isinstance(events, list) or len(events) > (MAX_EVENTS if kind == "day" else MAX_MONTH_EVENTS) or not isinstance(dates, dict) or len(dates) > MAX_QUERY_DAYS:
            return False
        if kind == "day" and dates:
            return False
        if kind == "month" and set(dates) != {(start + timedelta(days=i)).isoformat() for i in range((end - start).days)}:
            return False
        for event in events:
            if not isinstance(event, dict) or set(event) != {"id", "title", "calendar", "color", "location", "allDay", "start", "end", "startDate", "endDate"}:
                return False
            for key, limit in {**TEXT_LIMITS, "id": 100, "color": 9, "startDate": 10, "endDate": 10}.items():
                if (not isinstance(event[key], str) or len(event[key]) > limit
                        or re.search(r"[\x00-\x1f]", event[key])):
                    return False
            if event["color"] != normalize_color(event["color"]) or type(event["allDay"]) is not bool:
                return False
            if any(type(event[key]) is not int or not -62135596800 <= event[key] <= 253402300799 for key in ("start", "end")):
                return False
            if event["allDay"] and date.fromisoformat(event["endDate"]) <= date.fromisoformat(event["startDate"]):
                return False
        for key, day in dates.items():
            if not isinstance(day, dict) or set(day) != {"events", "state", "complete", "updatedAt", "cached"}:
                return False
            if not isinstance(day["events"], list) or len(day["events"]) > MAX_EVENTS:
                return False
            if any(type(index) is not int or not 0 <= index < len(events) for index in day["events"]):
                return False
            if len(set(day["events"])) != len(day["events"]):
                return False
            if day["state"] not in ("ok", "partial", "error", "missing"):
                return False
            if type(day["complete"]) is not bool or type(day["cached"]) is not bool:
                return False
            if type(day["updatedAt"]) is not int or not 0 <= day["updatedAt"] <= 253402300799:
                return False
        return len(encode(payload)) <= (MAX_RESPONSE_BYTES if kind == "day" else MAX_MONTH_BYTES)
    except (TypeError, ValueError, KeyError, OverflowError):
        return False


def default_cache_path() -> Path:
    return Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "foamy-clock" / "agenda-v3.json"


def cache_key(kind: str, start: date, end: date) -> str:
    return f"{kind}:{start}:{end}"


def read_cache(path: Path | None = None) -> dict[str, Any]:
    empty = {"version": CACHE_VERSION, "zone": str(local_timezone()), "views": {}}
    try:
        with (path or default_cache_path()).open("rb") as handle:
            raw = handle.read(MAX_CACHE_BYTES + 1)
        if len(raw) > MAX_CACHE_BYTES:
            return empty
        payload = json.loads(raw)
        if not isinstance(payload, dict) or set(payload) != {"version", "zone", "views"}:
            return empty
        views = payload.get("views")
        if payload.get("version") != CACHE_VERSION or payload.get("zone") != empty["zone"] or not isinstance(views, dict) or len(views) > MAX_CACHE_ENTRIES:
            return empty
        if any(not valid_payload(view) or key != cache_key(view["kind"], date.fromisoformat(view["date"]), date.fromisoformat(view["rangeEnd"])) for key, view in views.items()):
            return empty
        return payload
    except (OSError, ValueError, TypeError, AttributeError, RecursionError):
        return empty


def cached_view(kind: str, start: date, end: date, path: Path | None = None) -> dict[str, Any]:
    payload = dict(read_cache(path)["views"].get(cache_key(kind, start, end), base_payload(kind, start, end)))
    payload["cached"] = True
    return payload


def store_view(payload: dict[str, Any], path: Path | None = None) -> bool:
    if not valid_payload(payload) or payload["state"] not in ("ok", "partial"):
        return False
    path = path or default_cache_path()
    cache = read_cache(path)
    views = cache["views"]
    key = cache_key(payload["kind"], date.fromisoformat(payload["date"]), date.fromisoformat(payload["rangeEnd"]))
    old = views.get(key)
    # Preserve complete data when a refresh only saw part of the calendar.
    if payload["kind"] == "day" and old and old["complete"] and not payload["complete"]:
        return False
    views.pop(key, None)
    views[key] = payload
    while len(views) > MAX_CACHE_ENTRIES or len(encode(cache)) > MAX_CACHE_BYTES:
        del views[next(iter(views))]
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(dir=path.parent, prefix=".agenda-")
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(encode(cache))
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)
    return True


def run_bounded_worker(command: list[str], timeout: float = WORKER_SECONDS, max_bytes: int = MAX_RESPONSE_BYTES) -> dict[str, Any] | None:
    """Never hand an unbounded pipe to Qt, even if the worker malfunctions."""
    output = bytearray()
    deadline = monotonic_time.monotonic() + timeout
    # glibc's default per-thread arenas reserve large virtual ranges even for
    # small calendars. Bound arenas before exec so RLIMIT_AS reflects useful work.
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                          env={**os.environ, "MALLOC_ARENA_MAX": "2"}) as process:
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                while True:
                    remaining = deadline - monotonic_time.monotonic()
                    if remaining <= 0 or not selector.select(remaining):
                        return None
                    chunk = os.read(process.stdout.fileno(), min(8192, max_bytes + 1 - len(output)))
                    if not chunk:
                        break
                    output.extend(chunk)
                    if len(output) > max_bytes:
                        return None
            if process.wait(timeout=max(0.001, deadline - monotonic_time.monotonic())) != 0:
                return None
            payload = json.loads(output)
            return payload if valid_payload(payload) else None
        except (OSError, ValueError, RecursionError, subprocess.TimeoutExpired):
            return None
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()


def merge_month(fresh, cached):
    """Retain complete cached dates individually without hiding fresh good dates."""
    builder = MonthBuilder(date.fromisoformat(fresh["date"]), date.fromisoformat(fresh["rangeEnd"]))
    builder.payload.update(selectedCalendars=fresh["selectedCalendars"] or cached["selectedCalendars"], updatedAt=fresh["updatedAt"])
    for key, day in fresh["dates"].items():
        old = cached["dates"][key]
        keep_old = not day["complete"] and (old["complete"] or day["state"] == "error" and old["state"] in ("ok", "partial"))
        source, chosen = (cached, old) if keep_old else (fresh, day)
        for index in chosen["events"]:
            builder.add(source["events"][index], [key])
        rebuilt = builder.payload["dates"][key]
        overflow = not rebuilt["complete"]
        rebuilt.update({field: value for field, value in chosen.items() if field != "events"})
        if keep_old:
            rebuilt.update(state="partial", cached=True)
        if overflow:
            rebuilt.update(state="partial", complete=False)
    return builder.finish()


def emit_view(payload):
    if payload["kind"] == "day":
        print(encode(payload).decode("utf-8"), flush=True)
        return
    # Each line stays below the existing shell pipe limit. A month is at most
    # one header, ten 100-event chunks and a commit marker; apply it atomically.
    header = {**payload, "kind": "month-start", "events": []}
    messages = [header]
    for offset in range(0, len(payload["events"]), MAX_EVENTS):
        messages.append({"kind": "month-events", "date": payload["date"],
                         "rangeEnd": payload["rangeEnd"], "events": payload["events"][offset:offset + MAX_EVENTS]})
    messages.append({"kind": "month-end", "date": payload["date"], "rangeEnd": payload["rangeEnd"]})
    for message in messages:
        raw = encode(message)
        if len(raw) > MAX_RESPONSE_BYTES:
            raise ValueError("calendar message exceeds byte limit")
        print(raw.decode("utf-8"), flush=True)


def refreshed_view(kind: str, start: date, end: date, path: Path | None = None) -> dict[str, Any]:
    command = [sys.executable, str(Path(__file__).resolve()), "--worker", kind,
               "--date", start.isoformat(), "--range-end", end.isoformat()]
    fresh = run_bounded_worker(command, max_bytes=MAX_MONTH_BYTES if kind == "month" else MAX_RESPONSE_BYTES)
    if fresh is None or fresh["kind"] != kind or fresh["date"] != start.isoformat() or fresh["rangeEnd"] != end.isoformat():
        fresh = base_payload(kind, start, end, "error")
    cached = cached_view(kind, start, end, path)
    if kind == "month":
        fresh = merge_month(fresh, cached)
    elif fresh["state"] in ("partial", "error") and cached["complete"]:
        cached["state"] = "partial"
        fresh = cached
    try:
        store_view(fresh, path)
    except OSError:
        # A cache failure must not discard the usable live result.
        fresh["state"] = "partial" if fresh["state"] == "ok" else fresh["state"]
    return fresh


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--date", type=date.fromisoformat, default=date.today())
    parser.add_argument("--cached", action="store_true")
    parser.add_argument("--cache-only", action="store_true", help="refresh the bounded disk cache without sending event data to the shell")
    parser.add_argument("--max-age", type=int, default=0)
    parser.add_argument("--range-start", type=date.fromisoformat)
    parser.add_argument("--range-end", type=date.fromisoformat)
    parser.add_argument("--worker", choices=("day", "month"), help=argparse.SUPPRESS)
    arguments = parser.parse_args()
    if arguments.worker:
        # Set this before importing GI: C allocations and recurrence expansion
        # are outside Python's collection budgets. No additional service needed.
        resource.setrlimit(resource.RLIMIT_AS, (WORKER_MEMORY_BYTES, WORKER_MEMORY_BYTES))
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        try:
            payload = load_view(arguments.worker, arguments.date, arguments.range_end)
        except Exception:
            payload = base_payload(arguments.worker, arguments.date, arguments.range_end, "error")
        sys.stdout.buffer.write(encode(payload))
        return 0
    if (arguments.range_start is None) != (arguments.range_end is None):
        parser.error("range start and end must be provided together")
    if arguments.range_start and not 0 < (arguments.range_end - arguments.range_start).days <= MAX_QUERY_DAYS:
        parser.error("range must contain 1-42 days")
    # The bridge never imports GI. Disk reads, the worker's month response,
    # and every shell message have independent byte limits.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    views = [("month", arguments.range_start, arguments.range_end)] if arguments.range_start else [
        ("day", arguments.date, arguments.date + timedelta(days=1))
    ]
    for kind, start, end in views:
        cached = cached_view(kind, start, end)
        age = datetime.now().timestamp() - cached["updatedAt"]
        reusable = cached["state"] == "ok" and 0 <= age < min(86400, arguments.max_age)
        payload = cached if arguments.cached or reusable else refreshed_view(kind, start, end)
        if (arguments.cached or reusable) and payload["state"] in ("ok", "partial"):
            try:
                store_view(payload)
            except OSError:
                pass  # Cache access-order maintenance does not invalidate saved data.
        if not valid_payload(payload):
            payload = base_payload(kind, start, end, "error")
        if not arguments.cache_only:
            emit_view(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
