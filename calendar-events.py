#!/usr/bin/env python3

"""Read and cache selected Evolution calendar events as JSON."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import date, datetime, time, timedelta
import json
import os
from pathlib import Path
import re
import tempfile
from typing import Any


DEFAULT_COLOR = ""
UNTITLED_EVENT = "Untitled event"
CACHE_VERSION = 1
CACHE_MAX_DATES = 366
MAX_QUERY_DAYS = 370


def normalize_color(value: object) -> str:
    """Return a QML-safe hex color for Evolution's accepted color formats."""

    text = str(value or "").strip()
    if re.fullmatch(r"#[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?", text):
        return text.lower()

    match = re.fullmatch(
        r"rgb\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*\)", text
    )
    if not match:
        return DEFAULT_COLOR

    channels = [min(255, int(channel)) for channel in match.groups()]
    return "#" + "".join(f"{channel:02x}" for channel in channels)


def clean_text(value: object, fallback: str = "") -> str:
    text = " ".join(str(value or "").split())
    return text or fallback


def ical_date(value: Any) -> date:
    return date(value.get_year(), value.get_month(), value.get_day())


def unix_timestamp(value: Any, fallback_timezone: Any) -> int:
    """Convert an occurrence using its timezone before the client fallback."""

    timezone = value.get_timezone() or fallback_timezone
    return int(value.as_timet_with_zone(timezone))


def fetch_source_events(
    source: Any,
    source_name: str,
    source_color: str,
    range_start: datetime,
    range_end: datetime,
    ecal: Any,
    ical: Any,
) -> tuple[list[dict[str, Any]], str]:
    """Fetch one source independently so unavailable accounts do not hide others."""

    events: list[dict[str, Any]] = []

    try:
        client = ecal.Client.connect_sync(
            source, ecal.ClientSourceType.EVENTS, 2, None
        )

        def add_instance(
            component: Any,
            instance_start: Any,
            instance_end: Any,
            _data: object,
            _cancellable: object,
        ) -> bool:
            if component.get_status() == ical.PropertyStatus.CANCELLED:
                return True

            all_day = bool(instance_start.is_date())
            source_uid = clean_text(source.get_uid())
            event_uid = clean_text(component.get_uid())
            summary = clean_text(component.get_summary(), UNTITLED_EVENT)
            location = clean_text(component.get_location())

            if all_day:
                start_date = ical_date(instance_start)
                end_date = ical_date(instance_end)
                if end_date <= start_date:
                    end_date = start_date + timedelta(days=1)
                if end_date <= range_start.date() or start_date >= range_end.date():
                    return True

                occurrence = start_date.isoformat()
                events.append(
                    {
                        "id": f"{source_uid}:{event_uid}:{occurrence}",
                        "title": summary,
                        "calendar": source_name,
                        "color": source_color,
                        "location": location,
                        "allDay": True,
                        "start": 0,
                        "end": 0,
                        "startDate": start_date.isoformat(),
                        "endDate": end_date.isoformat(),
                    }
                )
                return True

            fallback_timezone = client.get_default_timezone()
            start_timestamp = unix_timestamp(instance_start, fallback_timezone)
            end_timestamp = unix_timestamp(instance_end, fallback_timezone)
            if start_timestamp >= int(range_end.timestamp()) or end_timestamp < int(
                range_start.timestamp()
            ):
                return True

            events.append(
                {
                    "id": f"{source_uid}:{event_uid}:{start_timestamp}",
                    "title": summary,
                    "calendar": source_name,
                    "color": source_color,
                    "location": location,
                    "allDay": False,
                    "start": start_timestamp,
                    "end": max(start_timestamp, end_timestamp),
                    "startDate": "",
                    "endDate": "",
                }
            )
            return True

        client.generate_instances_sync(
            int(range_start.timestamp()),
            int(range_end.timestamp()),
            None,
            add_instance,
            None,
        )
    except Exception:
        # Account and transport details belong in Evolution; the panel only
        # needs to report that one selected source could not be refreshed.
        return events, "unavailable"

    return events, ""


def build_date_payloads(
    range_start_date: date,
    range_end_date: date,
    events: list[dict[str, Any]],
    selected_calendars: int,
    failed_calendars: int,
    updated_at: int,
    timezone: Any,
) -> list[dict[str, Any]]:
    """Split one EDS range response into cacheable day payloads."""

    if selected_calendars and failed_calendars == selected_calendars:
        state = "error"
        message = "Calendar data is unavailable"
    elif failed_calendars:
        state = "partial"
        message = (
            f"{failed_calendars} calendar"
            f"{'s' if failed_calendars != 1 else ''} could not refresh"
        )
    else:
        state = "ok"
        message = ""

    payloads: list[dict[str, Any]] = []
    day_count = (range_end_date - range_start_date).days
    for offset in range(day_count):
        target_date = range_start_date + timedelta(days=offset)
        day_start = datetime.combine(target_date, time.min, timezone)
        day_end = day_start + timedelta(days=1)
        day_start_timestamp = int(day_start.timestamp())
        day_end_timestamp = int(day_end.timestamp())
        day_events: list[dict[str, Any]] = []

        for event in events:
            if event["allDay"]:
                event_start_date = date.fromisoformat(event["startDate"])
                event_end_date = date.fromisoformat(event["endDate"])
                if event_start_date <= target_date < event_end_date:
                    day_events.append(event)
                continue

            event_start = int(event["start"])
            event_end = max(event_start + 1, int(event["end"]))
            if event_start < day_end_timestamp and event_end > day_start_timestamp:
                day_events.append(event)

        day_events.sort(
            key=lambda event: (
                0 if event["allDay"] else 1,
                event["startDate"] if event["allDay"] else event["start"],
                event["title"].casefold(),
            )
        )
        payloads.append(
            {
                "state": state,
                "message": message,
                "date": target_date.isoformat(),
                "events": day_events,
                "selectedCalendars": selected_calendars,
                "failedCalendars": failed_calendars,
                "updatedAt": updated_at,
                "cached": False,
            }
        )

    return payloads


def load_date_range_events(
    range_start_date: date,
    range_end_date: date,
    now: datetime | None = None,
) -> list[dict[str, Any]]:
    """Fetch a bounded date range once and return one payload per day."""

    day_count = (range_end_date - range_start_date).days
    if day_count <= 0 or day_count > MAX_QUERY_DAYS:
        raise ValueError(f"calendar range must contain 1-{MAX_QUERY_DAYS} days")

    import gi

    gi.require_version("ECal", "2.0")
    gi.require_version("EDataServer", "1.2")
    gi.require_version("ICalGLib", "4.0")

    from gi.repository import ECal, EDataServer, ICalGLib

    local_now = now or datetime.now().astimezone()
    local_timezone = local_now.tzinfo or datetime.now().astimezone().tzinfo
    range_start = datetime.combine(range_start_date, time.min, local_timezone)
    range_end = datetime.combine(range_end_date, time.min, local_timezone)

    registry = EDataServer.SourceRegistry.new_sync(None)
    selected_sources: list[tuple[Any, str, str]] = []

    for source in registry.list_sources(EDataServer.SOURCE_EXTENSION_CALENDAR):
        extension = source.get_extension(EDataServer.SOURCE_EXTENSION_CALENDAR)
        if not source.get_enabled() or not extension.get_selected():
            continue
        selected_sources.append(
            (
                source,
                clean_text(source.get_display_name(), "Calendar"),
                normalize_color(extension.get_color()),
            )
        )

    events: list[dict[str, Any]] = []
    failures = 0

    # Sources are independent EDS clients. Querying them concurrently keeps a
    # slow remote account from serially delaying every other local cache.
    with ThreadPoolExecutor(max_workers=min(16, max(1, len(selected_sources)))) as pool:
        pending = {
            pool.submit(
                fetch_source_events,
                source,
                source_name,
                source_color,
                range_start,
                range_end,
                ECal,
                ICalGLib,
            ): source_name
            for source, source_name, source_color in selected_sources
        }
        for future in as_completed(pending):
            source_events, error = future.result()
            events.extend(source_events)
            failures += int(bool(error))

    return build_date_payloads(
        range_start_date,
        range_end_date,
        events,
        len(selected_sources),
        failures,
        int(local_now.timestamp()),
        local_timezone,
    )


def load_date_events(
    target_date: date, now: datetime | None = None
) -> dict[str, Any]:
    return load_date_range_events(target_date, target_date + timedelta(days=1), now)[0]


def load_today_events(now: datetime | None = None) -> dict[str, Any]:
    local_now = now or datetime.now().astimezone()
    return load_date_events(local_now.date(), local_now)


def default_cache_path() -> Path:
    configured_root = os.environ.get("XDG_CACHE_HOME", "").strip()
    cache_root = (
        Path(configured_root).expanduser()
        if configured_root
        else Path.home() / ".cache"
    )
    return cache_root / "foamy-clock" / "agenda-v1.json"


def read_cache(path: Path | None = None) -> dict[str, Any]:
    cache_path = path or default_cache_path()
    try:
        payload = json.loads(cache_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, TypeError):
        return {"version": CACHE_VERSION, "dates": {}}

    if not isinstance(payload, dict):
        return {"version": CACHE_VERSION, "dates": {}}
    dates = payload.get("dates")
    if payload.get("version") != CACHE_VERSION or not isinstance(dates, dict):
        return {"version": CACHE_VERSION, "dates": {}}
    return {"version": CACHE_VERSION, "dates": dates}


def cached_date_payload(
    target_date: date, path: Path | None = None
) -> dict[str, Any]:
    date_key = target_date.isoformat()
    cached = read_cache(path).get("dates", {}).get(date_key)
    if not isinstance(cached, dict) or not isinstance(cached.get("events"), list):
        return missing_date_payload(target_date)

    payload = dict(cached)
    payload.update(
        {
            "state": "cached",
            "message": "Showing cached calendar data",
            "date": date_key,
            "cached": True,
        }
    )
    return payload


def missing_date_payload(target_date: date) -> dict[str, Any]:
    return {
        "state": "missing",
        "message": "",
        "date": target_date.isoformat(),
        "events": [],
        "selectedCalendars": 0,
        "failedCalendars": 0,
        "updatedAt": 0,
        "cached": True,
    }


def store_date_payloads(
    payloads: list[dict[str, Any]], path: Path | None = None
) -> bool:
    good_payloads = [
        payload
        for payload in payloads
        if payload.get("state") == "ok" and isinstance(payload.get("events"), list)
    ]
    if not good_payloads:
        return False

    cache_path = path or default_cache_path()
    cache = read_cache(cache_path)
    dates = cache["dates"]
    for payload in good_payloads:
        stored_payload = dict(payload)
        stored_payload["cached"] = False
        dates[str(payload["date"])] = stored_payload

    if len(dates) > CACHE_MAX_DATES:
        newest = sorted(
            dates.items(),
            key=lambda item: int(item[1].get("updatedAt", 0)),
            reverse=True,
        )[:CACHE_MAX_DATES]
        cache["dates"] = dict(newest)

    cache_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=cache_path.parent, prefix=".agenda-", suffix=".json"
    )
    temporary_path = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(cache, handle, ensure_ascii=False, separators=(",", ":"))
            handle.write("\n")
        os.replace(temporary_path, cache_path)
    finally:
        temporary_path.unlink(missing_ok=True)
    return True


def store_date_payload(payload: dict[str, Any], path: Path | None = None) -> bool:
    return store_date_payloads([payload], path)


def parse_target_date(value: str) -> date:
    try:
        return date.fromisoformat(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("date must use YYYY-MM-DD") from error


def error_payload(target_date: date) -> dict[str, Any]:
    return {
        "state": "error",
        "message": "Calendar data is unavailable",
        "date": target_date.isoformat(),
        "events": [],
        "selectedCalendars": 0,
        "failedCalendars": 0,
        "updatedAt": int(datetime.now().timestamp()),
        "cached": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--date", type=parse_target_date, default=date.today())
    parser.add_argument("--cached", action="store_true")
    parser.add_argument("--range-start", type=parse_target_date)
    parser.add_argument("--range-end", type=parse_target_date)
    arguments = parser.parse_args()

    has_range = arguments.range_start is not None or arguments.range_end is not None
    if has_range and (arguments.range_start is None or arguments.range_end is None):
        parser.error("--range-start and --range-end must be used together")
    if arguments.cached and has_range:
        parser.error("--cached cannot be combined with a live range query")

    if arguments.cached:
        print(
            json.dumps(
                cached_date_payload(arguments.date),
                ensure_ascii=False,
                separators=(",", ":"),
            )
        )
        return 0

    try:
        if has_range:
            payloads = load_date_range_events(
                arguments.range_start, arguments.range_end
            )
            store_date_payloads(payloads)
            payload = next(
                (
                    item
                    for item in payloads
                    if item["date"] == arguments.date.isoformat()
                ),
                missing_date_payload(arguments.date),
            )
        else:
            payload = load_date_events(arguments.date)
            store_date_payload(payload)
    except Exception:
        payload = error_payload(arguments.date)

    if payload["state"] == "error":
        cached = cached_date_payload(arguments.date)
        if cached["state"] == "cached":
            payload = cached

    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
