#!/usr/bin/env python3

import contextlib
import importlib.util
import json
import os
import shutil
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch
from types import SimpleNamespace
import sys
import subprocess
from zoneinfo import ZoneInfo
import time


MODULE_PATH = Path(__file__).resolve().parents[1] / "calendar-events.py"
SPEC = importlib.util.spec_from_file_location("calendar_events", MODULE_PATH)
assert SPEC and SPEC.loader
CALENDAR_EVENTS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CALENDAR_EVENTS)
OSLO = ZoneInfo("Europe/Oslo")


class FakeDate:
    """An ICalGLib DATE value."""

    def __init__(self, day):
        self.day = day

    def is_date(self):
        return True

    def get_year(self):
        return self.day.year

    def get_month(self):
        return self.day.month

    def get_day(self):
        return self.day.day


class FakeDateTime:
    """An ICalGLib DATE-TIME: a wall-clock time and the zone it carries (None:
    none of its own, as for a floating time or one written with a TZID)."""

    def __init__(self, wall, zone):
        self.wall = wall
        self.zone = zone

    def is_date(self):
        return False

    def is_utc(self):
        return self.zone is timezone.utc

    def get_timezone(self):
        return self.zone

    def as_timet_with_zone(self, zone):
        return int(self.wall.replace(tzinfo=zone).timestamp())


def november(day, hour=None, zone=OSLO):
    """An occurrence's start and end on that day of November 2026, as libecal
    yields them (zone resolved): an hour from `hour`, or the whole day."""
    if hour is None:
        return FakeDate(date(2026, 11, day)), FakeDate(date(2026, 11, day + 1))
    return FakeDateTime(datetime(2026, 11, day, hour), zone), FakeDateTime(datetime(2026, 11, day, hour + 1), zone)


# A zone only the fake calendar defines (libical has no such built-in zone),
# and the zones the calendar resolves by TZID; it knows no other TZID.
PLUS_TWO = timezone(timedelta(hours=2), "Custom UTC+02")
CALENDAR_ZONES = {"Europe/Oslo": OSLO, "Custom UTC+02": PLUS_TWO}


def master(uid, times, title=None):
    """One of a recurring master's occurrences as libecal yields it: with
    the series' rule, and its start as RECURRENCE-ID, in UTC (an all-day
    one: its date)."""
    start, end = times
    recurrence_id = start
    if not start.is_date():
        in_utc = start.wall.replace(tzinfo=start.zone).astimezone(timezone.utc).replace(tzinfo=None)
        recurrence_id = FakeDateTime(in_utc, timezone.utc)
    return (uid, True, recurrence_id, start, end, title or uid.title())


def single(uid, times):
    """A single event's occurrence: no rule and no RECURRENCE-ID."""
    return (uid, False, None, *times, uid.title())


# A local Evolution calendar with weekly events from 6 November 2026 whose
# occurrences were moved (detached instances), for the private
# evolution-data-server test: out of the November view (a timed, an all-day
# and an unknown-zone event), onto another moved occurrence's old time, and
# swapped; the last two keep the series' rule, as an app can leave it.
MOVED_CALENDAR = """BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//foamy-clock//moved occurrences//EN
BEGIN:VTIMEZONE
TZID:Europe/Oslo
BEGIN:STANDARD
DTSTART:19701025T030000
RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU
TZOFFSETFROM:+0200
TZOFFSETTO:+0100
END:STANDARD
BEGIN:DAYLIGHT
DTSTART:19700329T020000
RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU
TZOFFSETFROM:+0100
TZOFFSETTO:+0200
END:DAYLIGHT
END:VTIMEZONE
BEGIN:VEVENT
UID:weekly@foamy-clock.test
DTSTAMP:20261101T000000Z
DTSTART;TZID=Europe/Oslo:20261106T090000
DTEND;TZID=Europe/Oslo:20261106T100000
RRULE:FREQ=WEEKLY;COUNT=8
SUMMARY:Weekly
END:VEVENT
BEGIN:VEVENT
UID:weekly@foamy-clock.test
DTSTAMP:20261101T000000Z
RECURRENCE-ID;TZID=Europe/Oslo:20261127T090000
DTSTART;TZID=Europe/Oslo:20270115T090000
DTEND;TZID=Europe/Oslo:20270115T100000
SUMMARY:Weekly moved away
END:VEVENT
BEGIN:VEVENT
UID:all-day@foamy-clock.test
DTSTAMP:20261101T000000Z
DTSTART;VALUE=DATE:20261106
DTEND;VALUE=DATE:20261107
RRULE:FREQ=WEEKLY;COUNT=8
SUMMARY:All day
END:VEVENT
BEGIN:VEVENT
UID:all-day@foamy-clock.test
DTSTAMP:20261101T000000Z
RECURRENCE-ID;VALUE=DATE:20261127
DTSTART;VALUE=DATE:20270115
DTEND;VALUE=DATE:20270116
SUMMARY:All day moved away
END:VEVENT
BEGIN:VEVENT
UID:unknown-zone@foamy-clock.test
DTSTAMP:20261101T000000Z
DTSTART;TZID=Nowhere/Unknown:20261106T160000
DTEND;TZID=Nowhere/Unknown:20261106T170000
RRULE:FREQ=WEEKLY;COUNT=8
SUMMARY:Unknown zone
END:VEVENT
BEGIN:VEVENT
UID:unknown-zone@foamy-clock.test
DTSTAMP:20261101T000000Z
RECURRENCE-ID;TZID=Nowhere/Unknown:20261127T160000
DTSTART;TZID=Nowhere/Unknown:20270115T160000
DTEND;TZID=Nowhere/Unknown:20270115T170000
SUMMARY:Unknown zone moved away
END:VEVENT
BEGIN:VEVENT
UID:overlap@foamy-clock.test
DTSTAMP:20261101T000000Z
DTSTART;TZID=Europe/Oslo:20261106T100000
DTEND;TZID=Europe/Oslo:20261106T110000
RRULE:FREQ=WEEKLY;COUNT=8
SUMMARY:Overlap
END:VEVENT
BEGIN:VEVENT
UID:overlap@foamy-clock.test
DTSTAMP:20261101T000000Z
RECURRENCE-ID;TZID=Europe/Oslo:20261120T100000
DTSTART;TZID=Europe/Oslo:20261127T100000
DTEND;TZID=Europe/Oslo:20261127T110000
RRULE:FREQ=WEEKLY;COUNT=8
SUMMARY:Overlap from 20 Nov
END:VEVENT
BEGIN:VEVENT
UID:overlap@foamy-clock.test
DTSTAMP:20261101T000000Z
RECURRENCE-ID;TZID=Europe/Oslo:20261127T100000
DTSTART;TZID=Europe/Oslo:20270115T100000
DTEND;TZID=Europe/Oslo:20270115T110000
RRULE:FREQ=WEEKLY;COUNT=8
SUMMARY:Overlap moved away
END:VEVENT
BEGIN:VEVENT
UID:swap@foamy-clock.test
DTSTAMP:20261101T000000Z
DTSTART;TZID=Europe/Oslo:20261106T120000
DTEND;TZID=Europe/Oslo:20261106T130000
RRULE:FREQ=WEEKLY;COUNT=8
SUMMARY:Swap
END:VEVENT
BEGIN:VEVENT
UID:swap@foamy-clock.test
DTSTAMP:20261101T000000Z
RECURRENCE-ID;TZID=Europe/Oslo:20261120T120000
DTSTART;TZID=Europe/Oslo:20261127T120000
DTEND;TZID=Europe/Oslo:20261127T130000
RRULE:FREQ=WEEKLY;COUNT=8
SUMMARY:Swap from 20 Nov
END:VEVENT
BEGIN:VEVENT
UID:swap@foamy-clock.test
DTSTAMP:20261101T000000Z
RECURRENCE-ID;TZID=Europe/Oslo:20261127T120000
DTSTART;TZID=Europe/Oslo:20261120T120000
DTEND;TZID=Europe/Oslo:20261120T130000
RRULE:FREQ=WEEKLY;COUNT=8
SUMMARY:Swap from 27 Nov
END:VEVENT
END:VCALENDAR
"""


def placed(uid, times, recurrence_id, title, rule_left=False):
    """A detached instance libecal placed: its own RECURRENCE-ID as libical
    reads it, and the series' rule only when it was left on it."""
    return (uid, rule_left, recurrence_id, *times, title)


def when(value, tzid=None):
    """An ECalComponentDateTime: a value and the TZID it was written with."""
    return SimpleNamespace(get_value=lambda: value, get_tzid=lambda: tzid)


def written(wall, tzid):
    """A DATE-TIME written with a TZID, as libecal hands it over: the value
    has no zone of its own, only the TZID names one."""
    return when(FakeDateTime(wall, None), tzid)


def utc(wall):
    """A DATE-TIME written in UTC (a Z time): libecal gives it its zone."""
    return when(FakeDateTime(wall, timezone.utc), "UTC")


class CalendarEventsTest(unittest.TestCase):
    def test_normalize_hex_color(self) -> None:
        self.assertEqual(CALENDAR_EVENTS.normalize_color("#83D754"), "#83d754")

    def test_normalize_rgb_color(self) -> None:
        self.assertEqual(CALENDAR_EVENTS.normalize_color("rgb(28,113,216)"), "#1c71d8")

    def test_invalid_color_uses_theme_accent(self) -> None:
        self.assertEqual(
            CALENDAR_EVENTS.normalize_color("not-a-color"),
            CALENDAR_EVENTS.DEFAULT_COLOR,
        )

    def test_clean_text_flattens_calendar_fields(self) -> None:
        self.assertEqual(CALENDAR_EVENTS.clean_text("  Planning\n  room  "), "Planning room")

    def test_timestamp_prefers_occurrence_timezone(self) -> None:
        occurrence_timezone = object()
        fallback_timezone = object()

        class Occurrence:
            def get_timezone(self):
                return occurrence_timezone

            def as_timet_with_zone(self, timezone):
                self.converted_with = timezone
                return 123

        occurrence = Occurrence()

        self.assertEqual(CALENDAR_EVENTS.unix_timestamp(occurrence, fallback_timezone), 123)
        self.assertIs(occurrence.converted_with, occurrence_timezone)

    def payload(self, state="ok", start=date(2026, 8, 24), events=()):
        """A 42-day month view; `events` all fall on its first date."""
        result = CALENDAR_EVENTS.base_payload(start, start + timedelta(days=42), state)
        result["updatedAt"] = 123456
        result["events"] = list(events)
        result["dates"][start.isoformat()]["events"] = list(range(len(result["events"])))
        return result

    def lines(self, payload):
        """The shell messages emit_view prints for a view, encoded."""
        with patch("builtins.print") as output:
            CALENDAR_EVENTS.emit_view(payload)
        return [call.args[0].encode() for call in output.call_args_list]

    def event(self, **values):
        result = {
            "id": "calendar:event:1",
            "title": "Planning",
            "location": "Room",
            "calendar": "Work",
            "color": "",
            "allDay": True,
            "start": 0,
            "end": 0,
            "startDate": "2026-08-24",
            "endDate": "2026-08-25",
        }
        result.update(values)
        return result

    def source(self, name="Work", enabled=True, selected=True, broken=False):
        """An Evolution calendar source as the registry lists it."""
        extension = SimpleNamespace(get_selected=lambda: selected, get_color=lambda: "#aabbcc")
        return SimpleNamespace(
            get_enabled=lambda: enabled,
            get_extension=lambda _: extension,
            get_display_name=lambda: name,
            get_uid=lambda: name,
            broken=broken,
        )

    def fake_gi(self, sources, ecal=None, ical=None):
        """sys.modules entries that make load_view see `sources`."""
        registry = SimpleNamespace(list_sources=lambda _: sources)
        data_server = SimpleNamespace(
            SourceRegistry=SimpleNamespace(new_sync=lambda _: registry), SOURCE_EXTENSION_CALENDAR="calendar"
        )
        repository = SimpleNamespace(ECal=ecal or object(), EDataServer=data_server, ICalGLib=ical or object())
        return {"gi": SimpleNamespace(require_version=lambda *_: None), "gi.repository": repository}

    def fetch(self, count, title="Planning", cancelled=False, span=1):
        class Occurrence:
            def __init__(self, day):
                self.day = day

            def is_date(self):
                return True

            def get_year(self):
                return self.day.year

            def get_month(self):
                return self.day.month

            def get_day(self):
                return self.day.day

        start = datetime(2026, 8, 24, tzinfo=timezone.utc)
        component = SimpleNamespace(
            get_status=lambda: "cancelled" if cancelled else "ok",
            get_summary=lambda: title,
            get_location=lambda: "Room",
            get_uid=lambda: f"event-{self.visited}",
        )
        self.visited = 0

        def generate(_start, _end, _cancel, callback, _data):
            for _ in range(count):
                self.visited += 1
                if not callback(
                    component, Occurrence(start.date()), Occurrence(start.date() + timedelta(days=span)), None, None
                ):
                    break

        client = SimpleNamespace(generate_instances_sync=generate)
        ecal = SimpleNamespace(
            Client=SimpleNamespace(connect_sync=lambda *_: client),
            ClientSourceType=SimpleNamespace(EVENTS=1),
            util_component_has_recurrences=lambda _component: False,
        )
        ical = SimpleNamespace(PropertyStatus=SimpleNamespace(CANCELLED="cancelled"))
        return CALENDAR_EVENTS.fetch_source_events(
            SimpleNamespace(get_uid=lambda: "calendar"),
            "Work",
            "#aabbcc",
            start,
            start + timedelta(days=42),
            ecal,
            ical,
        )

    def test_huge_unicode_fields_are_bounded_before_normalizing(self):
        month, error = self.fetch(1, title="🙂 \n" * 100000)
        self.assertLessEqual(len(month["events"][0]["title"]), 256)
        self.assertTrue(month["events"][0]["title"].endswith("…"))
        self.assertEqual(month["dates"]["2026-08-24"]["state"], "partial")
        self.assertEqual(error, "")
        payload = self.payload(
            events=[
                self.event(id=f"e{i}", title="🙂" * 256, location="🙂" * 128, calendar="🙂" * 80) for i in range(100)
            ]
        )
        self.assertTrue(CALENDAR_EVENTS.valid_payload(payload))
        self.assertTrue(all(len(line) < CALENDAR_EVENTS.MAX_RESPONSE_BYTES for line in self.lines(payload)))

    def test_control_characters_cannot_expand_shell_messages(self):
        month, _ = self.fetch(100, title="a\x01" * 128)
        self.assertEqual(len(month["events"]), 100)
        self.assertTrue(all("\x01" not in event["title"] for event in month["events"]))
        self.assertTrue(CALENDAR_EVENTS.valid_payload(month))
        self.assertTrue(all(len(line) < CALENDAR_EVENTS.MAX_RESPONSE_BYTES for line in self.lines(month)))

    def test_month_occurrence_work_is_bounded(self):
        month, error = self.fetch(200000)
        self.assertEqual(len(month["events"]), 100)
        self.assertEqual(self.visited, CALENDAR_EVENTS.MAX_OCCURRENCES + 1)
        self.assertEqual(month["state"], "partial")
        self.assertTrue(CALENDAR_EVENTS.valid_payload(month))

    def test_spanning_event_is_stored_once_for_all_dates(self):
        month, error = self.fetch(1, span=42)
        self.assertEqual(len(month["events"]), 1)
        self.assertEqual(len(month["dates"]), 42)
        self.assertTrue(all(day["events"] == [0] for day in month["dates"].values()))
        self.assertEqual(month["state"], "ok")
        self.assertEqual(error, "")

    def test_busy_day_does_not_mark_other_days_incomplete(self):
        month, _ = self.fetch(101)
        self.assertEqual(month["dates"]["2026-08-24"]["state"], "partial")
        self.assertEqual(month["dates"]["2026-08-25"]["state"], "ok")
        self.assertEqual(month["dates"]["2026-08-25"]["events"], [])

    def test_month_has_total_event_and_encoded_byte_budgets(self):
        builder = CALENDAR_EVENTS.MonthBuilder(date(2026, 8, 1), date(2026, 9, 12))
        keys = list(builder.payload["dates"])
        for i in range(4200):
            builder.add(
                self.event(id=f"event-{i}", title="🙂" * 256, location="🙂" * 128, calendar="🙂" * 80), [keys[i % 42]]
            )
        month = builder.finish()
        self.assertLessEqual(len(month["events"]), CALENDAR_EVENTS.MAX_MONTH_EVENTS)
        self.assertLessEqual(len(CALENDAR_EVENTS.encode(month)), CALENDAR_EVENTS.MAX_MONTH_BYTES)
        self.assertEqual(month["state"], "partial")
        self.assertTrue(CALENDAR_EVENTS.valid_payload(month))
        lines = self.lines(month)
        self.assertLessEqual(len(lines), 12)
        self.assertTrue(all(len(line) <= CALENDAR_EVENTS.MAX_RESPONSE_BYTES for line in lines))
        self.assertLess(sum(map(len, lines)), CALENDAR_EVENTS.MAX_MONTH_BYTES + 65536)

    def test_month_cache_evicts_by_bytes_before_entry_limit(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "cache.json"
            for month in range(1, 7):
                start = date(2026, month, 1)
                builder = CALENDAR_EVENTS.MonthBuilder(start, start + timedelta(days=42))
                keys = list(builder.payload["dates"])
                for i in range(1000):
                    builder.add(
                        self.event(id=f"event-{i}", title="🙂" * 256, location="🙂" * 128, calendar="🙂" * 80),
                        [keys[i % 42]],
                    )
                CALENDAR_EVENTS.store_view(builder.finish(), path)
                self.assertLessEqual(path.stat().st_size, CALENDAR_EVENTS.MAX_CACHE_BYTES)
                if month == 4:
                    self.assertEqual(len(CALENDAR_EVENTS.read_cache(path)["views"]), 4)
            views = CALENDAR_EVENTS.read_cache(path)["views"]
            self.assertLess(len(views), 6)
            self.assertEqual(list(views.values())[-1]["date"], "2026-06-01")

    def test_valid_payload_rejects_malformed_months(self):
        """The gate for disk and worker data: one rule broken per row."""

        def date_refs(indices):
            return lambda p: p["dates"]["2026-08-24"].update(events=indices)

        def longer_range(p):
            p["rangeEnd"] = "2026-10-06"
            p["dates"]["2026-10-05"] = dict(p["dates"]["2026-10-04"])

        def many_events(p):
            p["events"] = [self.event(id=f"e{i}") for i in range(101)]
            p["dates"]["2026-08-24"]["events"] = list(range(101))

        rows = {
            "an index without an event": date_refs([0, 1]),
            "a duplicate index": date_refs([0, 0]),
            "an empty event": lambda p: p.update(events=[{}]),
            "updatedAt as text": lambda p: p.update(updatedAt="now"),
            "updatedAt as a bool": lambda p: p.update(updatedAt=True),
            "a 257-character title": lambda p: p.update(events=[self.event(title="x" * 257)]),
            "a control character in a title": lambda p: p.update(events=[self.event(title="a\x1b[31m")]),
            "a colour that is not normalized": lambda p: p.update(events=[self.event(color="Red")]),
            "101 indices on one date": many_events,
            "a range of 43 days": longer_range,
            "the removed one-day kind": lambda p: p.update(kind="day"),
        }
        self.assertTrue(CALENDAR_EVENTS.valid_payload(self.payload(events=[self.event()])))
        for name, mutate in rows.items():
            with self.subTest(name):
                payload = self.payload(events=[self.event()])
                mutate(payload)
                self.assertFalse(CALENDAR_EVENTS.valid_payload(payload))

    def test_failed_dates_keep_cached_events_while_good_dates_update(self):
        start, end = date(2026, 8, 24), date(2026, 8, 26)
        old = CALENDAR_EVENTS.MonthBuilder(start, end)
        old.add(self.event(), ["2026-08-24", "2026-08-25"])
        cached = old.finish()
        for day in cached["dates"].values():
            day["updatedAt"] = 100
        fresh = CALENDAR_EVENTS.base_payload(start, end, "ok")
        fresh["dates"]["2026-08-24"].update(state="partial", complete=False)
        fresh["dates"]["2026-08-25"]["updatedAt"] = 200
        result = CALENDAR_EVENTS.merge_month(fresh, cached)
        self.assertEqual(result["dates"]["2026-08-24"]["events"], [0])
        self.assertTrue(result["dates"]["2026-08-24"]["cached"])
        self.assertEqual(result["dates"]["2026-08-24"]["state"], "partial")
        self.assertEqual(result["dates"]["2026-08-24"]["updatedAt"], 100)
        self.assertEqual(result["dates"]["2026-08-25"]["events"], [])
        self.assertEqual(result["dates"]["2026-08-25"]["state"], "ok")
        self.assertEqual(result["dates"]["2026-08-25"]["updatedAt"], 200)

    def test_merged_month_counts_the_calendars_of_a_good_refresh(self):
        """A failed worker knows no calendars; a good refresh with none selected does."""
        start, end = date(2026, 8, 24), date(2026, 8, 26)
        old = CALENDAR_EVENTS.MonthBuilder(start, end)
        old.add(self.event(), ["2026-08-24"])
        cached = old.finish()
        cached["selectedCalendars"] = 2
        rows = {
            "every calendar deselected": ("ok", 0),
            "worker failed": ("error", 2),
        }
        for name, (state, expected) in rows.items():
            with self.subTest(name):
                result = CALENDAR_EVENTS.merge_month(CALENDAR_EVENTS.base_payload(start, end, state), cached)
                self.assertEqual(result["selectedCalendars"], expected)

    def test_refresh_stores_the_calendar_count_it_shows(self):
        """The disk copy gets the same calendar count as the refreshed month."""
        start, end = date(2026, 8, 24), date(2026, 10, 5)
        rows = {
            "every calendar deselected": (self.payload(), 0),
            "worker failed": (None, 2),
        }
        for name, (fresh, expected) in rows.items():
            with self.subTest(name), TemporaryDirectory() as directory:
                path = Path(directory) / "agenda.json"
                good = self.payload(events=[self.event()])
                good["selectedCalendars"] = 2
                self.assertTrue(CALENDAR_EVENTS.store_view(good, path))
                with patch.object(CALENDAR_EVENTS, "run_bounded_worker", return_value=fresh):
                    result = CALENDAR_EVENTS.refreshed_view(start, end, path)
                stored = CALENDAR_EVENTS.cached_view(start, end, path)
                self.assertEqual((result["selectedCalendars"], stored["selectedCalendars"]), (expected, expected))

    def test_cached_and_fresh_spanning_revisions_do_not_overwrite_each_other(self):
        start, end = date(2026, 8, 24), date(2026, 8, 26)
        old = CALENDAR_EVENTS.MonthBuilder(start, end)
        old.add(self.event(title="Old title"), ["2026-08-24", "2026-08-25"])
        fresh = CALENDAR_EVENTS.MonthBuilder(start, end)
        fresh.add(self.event(title="New title"), ["2026-08-25"])
        fresh.incomplete(["2026-08-24"])
        result = CALENDAR_EVENTS.merge_month(fresh.finish(), old.finish())
        titles = [result["events"][result["dates"][key]["events"][0]]["title"] for key in ("2026-08-24", "2026-08-25")]
        self.assertEqual(titles, ["Old title", "New title"])

    def test_cancelled_occurrences_still_have_a_work_budget(self):
        month, error = self.fetch(200000, cancelled=True)
        self.assertEqual(month["events"], [])
        self.assertEqual(month["state"], "partial")
        self.assertFalse(month["complete"])
        self.assertEqual(error, "")
        self.assertEqual(self.visited, CALENDAR_EVENTS.MAX_OCCURRENCES + 1)

    def test_spanning_and_exclusive_all_day_end(self):
        event = self.event(endDate="2026-08-26")
        self.assertTrue(CALENDAR_EVENTS.overlaps(event, date(2026, 8, 25), timezone.utc))
        self.assertFalse(CALENDAR_EVENTS.overlaps(event, date(2026, 8, 26), timezone.utc))

    def test_dst_day_uses_next_local_midnight(self):
        zone = ZoneInfo("Europe/Oslo")
        event = self.event(
            allDay=False,
            start=int(datetime(2026, 3, 30, 0, 30, tzinfo=zone).timestamp()),
            end=int(datetime(2026, 3, 30, 1, tzinfo=zone).timestamp()),
        )
        self.assertFalse(CALENDAR_EVENTS.overlaps(event, date(2026, 3, 29), zone))
        self.assertTrue(CALENDAR_EVENTS.overlaps(event, date(2026, 3, 30), zone))
        instant = self.event(allDay=False, start=int(datetime(2026, 10, 25, 23, 30, tzinfo=zone).timestamp()), end=0)
        self.assertTrue(CALENDAR_EVENTS.overlaps(instant, date(2026, 10, 25), zone))

    def test_cache_round_trip_and_partial_keeps_completeness(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "agenda.json"
            payload = self.payload("partial", events=[self.event()])
            self.assertTrue(CALENDAR_EVENTS.store_view(payload, path))
            cached = CALENDAR_EVENTS.cached_view(date(2026, 8, 24), date(2026, 10, 5), path)
            self.assertEqual(cached["state"], "partial")
            self.assertTrue(cached["cached"])
            self.assertFalse(cached["complete"])
            self.assertEqual(cached["updatedAt"], 123456)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_failed_refresh_preserves_good_data_and_persists_warning(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "agenda.json"
            good = self.payload(events=[self.event()])
            CALENDAR_EVENTS.store_view(good, path)
            start, end = date(2026, 8, 24), date(2026, 10, 5)
            for fresh in (None, self.payload("partial")):
                with patch.object(CALENDAR_EVENTS, "run_bounded_worker", return_value=fresh):
                    result = CALENDAR_EVENTS.refreshed_view(start, end, path)
                self.assertEqual(result["events"], good["events"])
                self.assertEqual(result["dates"]["2026-08-24"]["events"], [0])
                self.assertEqual(result["state"], "partial")
                self.assertTrue(all(day["cached"] and day["complete"] for day in result["dates"].values()))
                self.assertTrue(result["complete"])
                cached = CALENDAR_EVENTS.cached_view(start, end, path)
                self.assertEqual(cached["state"], "partial")
                self.assertEqual(cached["dates"], result["dates"])
                self.assertTrue(CALENDAR_EVENTS.valid_payload(cached))
            with patch.object(CALENDAR_EVENTS, "run_bounded_worker", return_value=good):
                recovered = CALENDAR_EVENTS.refreshed_view(start, end, path)
            self.assertEqual(recovered["state"], "ok")
            self.assertFalse(any(day["cached"] for day in recovered["dates"].values()))

    def test_cache_rejects_oversized_corrupt_and_old_files(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "agenda.json"
            for raw in (
                b" " * (CALENDAR_EVENTS.MAX_CACHE_BYTES + 1),
                b'{"version":1,"dates":{}}',
                b"[",
                b"null",
                b"[" * 2000,
            ):
                path.write_bytes(raw)
                self.assertEqual(CALENDAR_EVENTS.read_cache(path)["views"], {})

            def other_zone(cache):
                # Days were cut at another zone's midnight.
                cache["zone"] = "Pacific/Kiritimati" if cache["zone"] != "Pacific/Kiritimati" else "UTC"

            def bogus_state(cache):
                next(iter(cache["views"].values()))["state"] = "bogus"

            def wrong_key(cache):
                views = cache["views"]
                views["month:2026-08-25:2026-10-06"] = views.pop("month:2026-08-24:2026-10-05")

            def nine_views(cache):
                for offset in range(1, 9):
                    view = self.payload(start=date(2026, 8, 24) + timedelta(days=offset))
                    cache["views"][f"month:{view['date']}:{view['rangeEnd']}"] = view

            rows = {
                "another time zone": other_zone,
                "a view in an unknown state": bogus_state,
                "a key that does not match its range": wrong_key,
                "another cache version": lambda cache: cache.update(version=2),
                "nine views": nine_views,
            }
            for name, mutate in rows.items():
                with self.subTest(name):
                    path.unlink(missing_ok=True)
                    self.assertTrue(CALENDAR_EVENTS.store_view(self.payload(events=[self.event()]), path))
                    self.assertEqual(len(CALENDAR_EVENTS.read_cache(path)["views"]), 1)
                    cache = json.loads(path.read_bytes())
                    mutate(cache)
                    path.write_text(json.dumps(cache))
                    self.assertEqual(CALENDAR_EVENTS.read_cache(path)["views"], {})

    def test_cache_evicts_by_bytes_and_entry_count(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "agenda.json"
            for offset in range(20):
                payload = self.payload(
                    start=date(2026, 1, 1) + timedelta(days=offset),
                    events=[self.event(id=f"e{i}", title="🙂" * 256) for i in range(100)],
                )
                CALENDAR_EVENTS.store_view(payload, path)
                self.assertLessEqual(path.stat().st_size, CALENDAR_EVENTS.MAX_CACHE_BYTES)
            views = CALENDAR_EVENTS.read_cache(path)["views"]
            self.assertLessEqual(len(views), CALENDAR_EVENTS.MAX_CACHE_ENTRIES)
            self.assertNotIn("month:2026-01-01:2026-02-12", views)
            self.assertEqual(list(views.values())[-1]["date"], payload["date"])

    def test_worker_reader_rejects_bad_output_without_waiting(self):
        valid = json.dumps(self.payload())
        rows = {
            # Endless output: only a reader that stops at max_bytes returns.
            "endless stdout": (
                "import os\nwhile True:\n    os.write(1, b'x' * 65536)",
                CALENDAR_EVENTS.MAX_MONTH_BYTES,
            ),
            "1 MiB on stderr, {} on stdout": ("import os; os.write(2, b'x' * 1048576); os.write(1, b'{}')", None),
            "deeply nested JSON": ("print('[' * 2000)", None),
            "text that is not JSON": ("print('calendar unavailable')", None),
            "a valid month, then exit 3": (f"import sys; print({valid!r}); sys.exit(3)", None),
        }
        for name, (script, max_bytes) in rows.items():
            with self.subTest(name):
                limits = {} if max_bytes is None else {"max_bytes": max_bytes}
                started = time.monotonic()
                result = CALENDAR_EVENTS.run_bounded_worker([sys.executable, "-c", script], timeout=30, **limits)
                self.assertIsNone(result)
                self.assertLess(time.monotonic() - started, 10)

    def test_worker_reader_accepts_valid_payload(self):
        payload = self.payload()
        result = CALENDAR_EVENTS.run_bounded_worker([sys.executable, "-c", "print(" + repr(json.dumps(payload)) + ")"])
        self.assertEqual(result, payload)

    def test_missing_cache_and_failed_live_view_stay_unavailable(self):
        with TemporaryDirectory() as directory:
            with patch.object(CALENDAR_EVENTS, "run_bounded_worker", return_value=None):
                result = CALENDAR_EVENTS.refreshed_view(
                    date(2026, 8, 24), date(2026, 10, 5), Path(directory) / "cache.json"
                )
        self.assertEqual(result["state"], "error")
        self.assertFalse(result["complete"])

    def test_fresh_cached_navigation_does_not_start_a_worker(self):
        import os

        payload = self.payload()
        payload["updatedAt"] = int(time.time())
        with TemporaryDirectory() as directory:
            path = Path(directory) / "foamy-clock" / "agenda-v3.json"
            CALENDAR_EVENTS.store_view(payload, path)
            with (
                patch.dict(os.environ, {"XDG_CACHE_HOME": directory}),
                patch.object(
                    sys,
                    "argv",
                    [str(MODULE_PATH), "--range-start", "2026-08-24", "--range-end", "2026-10-05", "--max-age", "1800"],
                ),
                patch.object(CALENDAR_EVENTS, "run_bounded_worker", side_effect=AssertionError("unnecessary worker")),
                patch("builtins.print") as output,
            ):
                self.assertEqual(CALENDAR_EVENTS.main(), 0)
            result = json.loads(output.call_args_list[0].args[0])
            self.assertEqual(result["kind"], "month-start")
            self.assertTrue(result["cached"])
            self.assertEqual(result["state"], "ok")

    def test_worker_deadline_reaps_process(self):
        import signal

        started = []

        class Recording(subprocess.Popen):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, **kwargs)
                started.append(self)

        began = time.monotonic()
        with patch.object(CALENDAR_EVENTS.subprocess, "Popen", Recording):
            result = CALENDAR_EVENTS.run_bounded_worker(
                [sys.executable, "-c", "import time; time.sleep(60)"], timeout=0.2
            )
        self.assertIsNone(result)
        self.assertLess(time.monotonic() - began, 10)
        self.assertEqual(len(started), 1)
        self.assertEqual(started[0].returncode, -signal.SIGKILL)
        self.assertFalse(Path(f"/proc/{started[0].pid}").exists())

    def test_bridge_and_worker_end_when_their_wrapper_is_killed(self):
        """The shell's kill of `timeout` reaches the bridge and its hung worker."""
        import os
        import signal

        def alive(pid):
            try:
                return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0] != "Z"
            except OSError:
                return False

        def wait_until(condition):
            deadline = time.monotonic() + 10
            while not condition() and time.monotonic() < deadline:
                time.sleep(0.02)
            return condition()

        with TemporaryDirectory() as directory:
            record = Path(directory) / "worker"
            (Path(directory) / "gi").mkdir()
            (Path(directory) / "gi" / "__init__.py").write_text(
                "import os, time\n"
                "def require_version(*_):\n"
                f"    with open({str(record) + '.tmp'!r}, 'w') as handle:\n"
                "        handle.write(f'{os.getpid()} {os.getppid()}')\n"
                f"    os.replace({str(record) + '.tmp'!r}, {str(record)!r})\n"
                "    time.sleep(60)\n"
            )
            bridge = [sys.executable, str(MODULE_PATH), "--range-start", "2026-08-24", "--range-end", "2026-10-05"]
            # Stands in for `timeout` killed before it can pass a signal on.
            wrapper = subprocess.Popen(
                [sys.executable, "-c", "import subprocess, sys, time; subprocess.Popen(sys.argv[1:]); time.sleep(60)"]
                + bridge,
                env={**os.environ, "PYTHONPATH": directory, "XDG_CACHE_HOME": directory},
                stdout=subprocess.DEVNULL,
            )
            pids = []
            try:
                self.assertTrue(wait_until(record.exists), "the worker never started")
                pids = [int(pid) for pid in record.read_text().split()]
                wrapper.kill()
                wrapper.wait()
                self.assertTrue(wait_until(lambda: not any(alive(pid) for pid in pids)), "the bridge or worker runs on")
            finally:
                wrapper.kill()
                wrapper.wait()
                for pid in pids:
                    if alive(pid):
                        os.kill(pid, signal.SIGKILL)

    def test_source_count_concurrency_and_merged_events_are_bounded(self):
        import threading

        sources = [self.source() for _ in range(40)]
        active = peak = calls = 0
        lock = threading.Lock()

        def fetch(*_args):
            nonlocal active, peak, calls
            with lock:
                active += 1
                calls += 1
                peak = max(peak, active)
                call = calls
            time.sleep(0.002)
            with lock:
                active -= 1
            # Every source fills the day with its own 100 events.
            month = CALENDAR_EVENTS.MonthBuilder(date(2026, 8, 24), date(2026, 8, 25))
            for i in range(100):
                month.add(self.event(id=f"source-{call}:{i}"), ["2026-08-24"])
            return month.finish(), ""

        with (
            patch.dict(sys.modules, self.fake_gi(sources)),
            patch.object(CALENDAR_EVENTS, "fetch_source_events", side_effect=fetch),
        ):
            result = CALENDAR_EVENTS.load_view(date(2026, 8, 24), date(2026, 8, 25))
        self.assertEqual(calls, 32)
        self.assertLessEqual(peak, 2)
        self.assertEqual(len(result["dates"]["2026-08-24"]["events"]), 100)
        self.assertEqual(len(result["events"]), 100)
        self.assertEqual(result["state"], "partial")
        self.assertFalse(result["complete"])

    def test_unreachable_calendars_are_error_or_partial_never_empty_ok(self):
        """A calendar that cannot be reached must never read as a day without events."""
        opened = []

        class Day:
            def __init__(self, day):
                self.day = day

            def is_date(self):
                return True

            def get_year(self):
                return self.day.year

            def get_month(self):
                return self.day.month

            def get_day(self):
                return self.day.day

        def connect(source, *_):
            opened.append(source.get_display_name())
            if source.broken:
                raise OSError("account offline")
            component = SimpleNamespace(
                get_status=lambda: "confirmed",
                get_summary=lambda: source.get_display_name() + " offsite",
                get_location=lambda: "",
                get_uid=lambda: "offsite",
            )
            first = date(2026, 8, 24)
            return SimpleNamespace(
                set_default_timezone=lambda _zone: None,
                get_default_timezone=lambda: None,
                generate_instances_sync=lambda _s, _e, _c, callback, _d: callback(
                    component, Day(first), Day(first + timedelta(days=1)), None, None
                ),
            )

        ecal = SimpleNamespace(
            Client=SimpleNamespace(connect_sync=connect),
            ClientSourceType=SimpleNamespace(EVENTS=1),
            util_component_has_recurrences=lambda _component: False,
        )
        ical = SimpleNamespace(
            PropertyStatus=SimpleNamespace(CANCELLED="cancelled"),
            Timezone=SimpleNamespace(get_builtin_timezone=lambda _key: None),
        )
        rows = {
            "no selected calendar": [self.source("Off", enabled=False), self.source("Hidden", selected=False)],
            "one of two calendars broken": [self.source("Work"), self.source("Shared", broken=True)],
            "every calendar broken": [self.source("Work", broken=True), self.source("Shared", broken=True)],
        }
        results = {}
        for name, sources in rows.items():
            opened.clear()
            with patch.dict(sys.modules, self.fake_gi(sources, ecal, ical)):
                results[name] = CALENDAR_EVENTS.load_view(date(2026, 8, 24), date(2026, 10, 5)), list(opened)
            self.assertTrue(CALENDAR_EVENTS.valid_payload(results[name][0]), name)

        month, opened_now = results["no selected calendar"]
        self.assertEqual((month["state"], month["selectedCalendars"], month["complete"]), ("ok", 0, True))
        self.assertEqual(opened_now, [])

        month, _ = results["one of two calendars broken"]
        self.assertEqual(month["state"], "partial")
        self.assertFalse(month["complete"])
        self.assertEqual(month["selectedCalendars"], 2)
        self.assertEqual([event["title"] for event in month["events"]], ["Work offsite"])
        self.assertEqual(month["dates"]["2026-08-24"]["events"], [0])

        month, _ = results["every calendar broken"]
        self.assertEqual(month["state"], "error")
        self.assertTrue(all(day["state"] == "error" for day in month["dates"].values()))
        self.assertEqual(month["events"], [])

    def test_unreachable_evolution_registry_is_an_error_not_no_calendars(self):
        """The real libedataserver raises when its registry service has no bus.

        An empty source list would read as "No calendars selected"; the worker
        must report the month as failed instead.
        """
        try:
            import gi

            gi.require_version("EDataServer", "1.2")
            gi.require_version("ECal", "2.0")
            gi.require_version("ICalGLib", "4.0")
        except (ImportError, ValueError):
            self.skipTest("Evolution Data Server not installed")
        command = [
            sys.executable,
            str(MODULE_PATH),
            "--worker",
            "--range-start",
            "2026-08-24",
            "--range-end",
            "2026-10-05",
        ]
        with TemporaryDirectory() as directory:
            # The real libraries run: an explicit address keeps GDBus off the
            # real session bus, and a temporary home and runtime directory
            # keep GLib and dconf away from the user's files and session.
            runtime = Path(directory) / "runtime"
            runtime.mkdir(mode=0o700)
            isolated = {
                "DBUS_SESSION_BUS_ADDRESS": f"unix:path={directory}/no-bus",
                "HOME": f"{directory}/home",
                "XDG_CONFIG_HOME": f"{directory}/config",
                "XDG_CACHE_HOME": f"{directory}/cache",
                "XDG_DATA_HOME": f"{directory}/data",
                "XDG_STATE_HOME": f"{directory}/state",
                "XDG_RUNTIME_DIR": str(runtime),
            }
            with patch.dict("os.environ", isolated):
                month = CALENDAR_EVENTS.run_bounded_worker(command, max_bytes=CALENDAR_EVENTS.MAX_MONTH_BYTES)
        self.assertIsNotNone(month)
        self.assertEqual((month["state"], month["complete"]), ("error", False))
        self.assertTrue(all(day["state"] == "error" for day in month["dates"].values()))

    def test_failed_cache_write_keeps_the_old_file_and_the_live_result(self):
        start, end = date(2026, 8, 24), date(2026, 10, 5)
        with TemporaryDirectory() as directory:
            path = Path(directory) / "agenda.json"
            old = self.payload(events=[self.event(title="Old")])
            self.assertTrue(CALENDAR_EVENTS.store_view(old, path))
            fresh = self.payload(events=[self.event(title="New")])
            with (
                patch.object(CALENDAR_EVENTS, "run_bounded_worker", return_value=fresh),
                patch.object(CALENDAR_EVENTS.os, "replace", side_effect=OSError("disk full")),
            ):
                result = CALENDAR_EVENTS.refreshed_view(start, end, path)
            self.assertEqual([event["title"] for event in result["events"]], ["New"])
            self.assertEqual(result["state"], "partial")
            views = CALENDAR_EVENTS.read_cache(path)["views"]
            self.assertEqual([event["title"] for event in views["month:2026-08-24:2026-10-05"]["events"]], ["Old"])
            self.assertEqual([p.name for p in Path(directory).iterdir() if p.name.startswith(".agenda-")], [])

    def test_worker_memory_limit_turns_large_allocation_into_failure(self):
        script = (
            "import importlib.util,sys; "
            "s=importlib.util.spec_from_file_location('calendar_events', " + repr(str(MODULE_PATH)) + "); "
            "m=importlib.util.module_from_spec(s); s.loader.exec_module(m); "
            "m.load_view=lambda *_: bytearray(1024**3); "
            "sys.argv=['calendar-events.py','--worker','--range-start','2026-08-24','--range-end','2026-08-25']; "
            "m.main()"
        )
        result = CALENDAR_EVENTS.run_bounded_worker([sys.executable, "-c", script])
        self.assertIsNotNone(result)
        self.assertEqual(result["state"], "error")
        self.assertFalse(result["complete"])

    def test_cached_cli_emits_atomic_month_transaction(self):
        import os

        with TemporaryDirectory() as directory:
            command = [
                sys.executable,
                str(MODULE_PATH),
                "--cached",
                "--range-start",
                "2026-08-24",
                "--range-end",
                "2026-10-05",
            ]
            env = {**os.environ, "XDG_CACHE_HOME": directory}
            lines = [json.loads(line) for line in subprocess.check_output(command, env=env).splitlines()]
            self.assertEqual([item["kind"] for item in lines], ["month-start", "month-end"])
            self.assertEqual(len(lines[0]["dates"]), 42)
            self.assertEqual(lines[0]["state"], "missing")

            month = self.payload(events=[self.event(startDate="2026-08-25", endDate="2026-08-26")])
            month["dates"]["2026-08-24"]["events"] = []
            month["dates"]["2026-08-25"]["events"] = [0]
            path = Path(directory) / "foamy-clock" / f"agenda-v{CALENDAR_EVENTS.CACHE_VERSION}.json"
            self.assertTrue(CALENDAR_EVENTS.store_view(month, path))
            lines = [json.loads(line) for line in subprocess.check_output(command, env=env).splitlines()]
            self.assertEqual([item["kind"] for item in lines], ["month-start", "month-events", "month-end"])
            header, chunk, _ = lines
            self.assertEqual(header["events"], [])
            self.assertEqual(header["state"], "ok")
            self.assertEqual(header["dates"]["2026-08-25"]["events"], [0])
            self.assertEqual(chunk["events"], month["events"])
            self.assertTrue(all((item["date"], item["rangeEnd"]) == ("2026-08-24", "2026-10-05") for item in lines))

    def test_cli_rejects_missing_and_invalid_ranges(self):
        import os

        with TemporaryDirectory() as directory:
            env = {**os.environ, "XDG_CACHE_HOME": directory}
            rows = {
                "no range": [],
                "start only": ["--range-start", "2026-08-01"],
                "start equal to end": ["--range-start", "2026-08-01", "--range-end", "2026-08-01"],
                "43 days": ["--range-start", "2026-08-01", "--range-end", "2026-09-13"],
                "end before start": ["--range-start", "2026-08-02", "--range-end", "2026-08-01"],
                "a start that is not a date": ["--range-start", "today", "--range-end", "2026-08-01"],
            }
            for name, arguments in rows.items():
                with self.subTest(name):
                    result = subprocess.run(
                        [sys.executable, str(MODULE_PATH), "--cached", *arguments],
                        env=env,
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(result.returncode, 2)
                    self.assertEqual(result.stdout, "")
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_cache_only_refresh_persists_without_shell_output(self):
        start = date(2026, 8, 24)
        month = self.payload(start=start, events=[self.event()])
        with TemporaryDirectory() as directory:
            path = Path(directory) / "agenda.json"
            with (
                patch.object(
                    sys,
                    "argv",
                    [
                        "calendar-events.py",
                        "--cache-only",
                        "--range-start",
                        str(start),
                        "--range-end",
                        str(start + timedelta(days=42)),
                    ],
                ),
                patch.object(CALENDAR_EVENTS, "default_cache_path", return_value=path),
                patch.object(CALENDAR_EVENTS, "run_bounded_worker", return_value=month) as worker,
                patch.object(CALENDAR_EVENTS, "emit_view") as output,
            ):
                self.assertEqual(CALENDAR_EVENTS.main(), 0)
                worker.assert_called_once()
                output.assert_not_called()
            cached = CALENDAR_EVENTS.cached_view(start, start + timedelta(days=42), path)
            self.assertEqual(cached["events"], month["events"])
            self.assertEqual(cached["state"], "ok")

            # A restart reuses fresh prefetched data without an Exchange query.
            cached["updatedAt"] = int(time.time())
            CALENDAR_EVENTS.store_view(cached, path)
            with (
                patch.object(
                    sys,
                    "argv",
                    [
                        "calendar-events.py",
                        "--cache-only",
                        "--max-age",
                        "1800",
                        "--range-start",
                        str(start),
                        "--range-end",
                        str(start + timedelta(days=42)),
                    ],
                ),
                patch.object(CALENDAR_EVENTS, "default_cache_path", return_value=path),
                patch.object(CALENDAR_EVENTS, "run_bounded_worker", side_effect=AssertionError("unnecessary worker")),
                patch.object(CALENDAR_EVENTS, "emit_view") as output,
            ):
                self.assertEqual(CALENDAR_EVENTS.main(), 0)
                output.assert_not_called()

    def test_floating_times_use_the_local_default_timezone(self):
        """EDS resolves floating DATE-TIMEs with the client default zone (UTC unless set)."""
        oslo = object()
        calls = []

        class Occurrence:
            def __init__(self, hour):
                self.hour = hour

            def is_date(self):
                return False

            def get_timezone(self):
                return None  # floating: no TZID, no Z

            def as_timet_with_zone(self, zone):
                # 09:00 floating is 08:00 UTC in Oslo (CET), 09:00 UTC in UTC.
                offset = 3600 if zone is oslo else 0
                return int(datetime(2026, 10, 30, self.hour, tzinfo=timezone.utc).timestamp()) - offset

        component = SimpleNamespace(
            get_status=lambda: "ok", get_summary=lambda: "Standup", get_location=lambda: "", get_uid=lambda: "floating"
        )
        client = SimpleNamespace(
            set_default_timezone=lambda zone: calls.append(zone),
            get_default_timezone=lambda: calls[-1] if calls else "utc",
            generate_instances_sync=lambda _s, _e, _c, callback, _d: callback(
                component, Occurrence(9), Occurrence(10), None, None
            ),
        )
        ecal = SimpleNamespace(
            Client=SimpleNamespace(connect_sync=lambda *_: client),
            ClientSourceType=SimpleNamespace(EVENTS=1),
            util_component_has_recurrences=lambda _component: False,
        )
        ical = SimpleNamespace(PropertyStatus=SimpleNamespace(CANCELLED="cancelled"))
        start = datetime(2026, 10, 30, tzinfo=ZoneInfo("Europe/Oslo"))
        month, error = CALENDAR_EVENTS.fetch_source_events(
            SimpleNamespace(get_uid=lambda: "calendar"), "Work", "", start, start + timedelta(days=1), ecal, ical, oslo
        )
        self.assertEqual(error, "")
        self.assertEqual(calls, [oslo])
        self.assertEqual(month["dates"]["2026-10-30"]["events"], [0])
        self.assertEqual(datetime.fromtimestamp(month["events"][0]["start"], ZoneInfo("Europe/Oslo")).hour, 9)

    def fetch_series(self, occurrences, detached, cancelled=0, failing_lookup=False):
        """fetch_source_events over libecal as EDS 3.62 behaves for an
        occurrence moved out of the asked range: generate_instances_sync
        still yields the master's occurrence on the old date, and only the
        lookup by UID returns the detached instance.

        `occurrences` are what libecal yields, in its order, after `cancelled`
        cancelled ones: master(), single() and placed(). `detached` maps a
        UID to its detached instances: (RECURRENCE-ID, own start or None).
        The calendar knows the zones in CALENDAR_ZONES; tzlookup_cb gives
        None for another TZID, as in EDS. Returns the month, the error and the UIDs looked up; `self.read`
        counts the components read.
        """
        lookups = []
        generating = False
        read = 0

        def generate(_start, _end, _cancellable, callback, _data):
            nonlocal generating
            generating = True
            try:
                for _ in range(cancelled):
                    if not callback(SimpleNamespace(get_status=lambda: "cancelled"), None, None, None, None):
                        return
                for uid, rule, recurrence_id, start, end, title in occurrences:
                    component = SimpleNamespace(
                        get_status=lambda: "confirmed",
                        get_summary=lambda title=title: title,
                        get_location=lambda: "",
                        get_uid=lambda uid=uid: uid,
                        get_recurrenceid=lambda recurrence_id=recurrence_id: recurrence_id,
                        rule=rule,
                    )
                    if not callback(component, start, end, None, None):
                        return
            finally:
                generating = False

        def component(recurrence_id, start):
            def recurid():
                nonlocal read
                read += 1
                return None if recurrence_id is None else SimpleNamespace(get_datetime=lambda: recurrence_id)

            return SimpleNamespace(get_recurid=recurid, get_dtstart=lambda: start)

        def objects_for_uid(uid, _cancellable):
            self.assertFalse(generating, "a lookup inside generate_instances_sync's callback")
            lookups.append(uid)
            if failing_lookup:
                raise OSError("the calendar backend went away")
            master = component(None, written(datetime(2026, 11, 6, 10), "Europe/Oslo"))
            return True, [master, *(component(*instance) for instance in detached.get(uid, []))]

        client = SimpleNamespace(
            set_default_timezone=lambda _zone: None,
            get_default_timezone=lambda: OSLO,
            generate_instances_sync=generate,
            get_objects_for_uid_sync=objects_for_uid,
        )
        ecal = SimpleNamespace(
            Client=SimpleNamespace(
                connect_sync=lambda *_: client,
                tzlookup_cb=lambda tzid, _client, _cancellable: CALENDAR_ZONES.get(tzid),
            ),
            ClientSourceType=SimpleNamespace(EVENTS=1),
            util_component_has_recurrences=lambda component: component.rule,
        )
        ical = SimpleNamespace(PropertyStatus=SimpleNamespace(CANCELLED="cancelled"))
        start = datetime(2026, 10, 26, tzinfo=OSLO)
        month, error = CALENDAR_EVENTS.fetch_source_events(
            SimpleNamespace(get_uid=lambda: "calendar"), "Work", "", start, start + timedelta(days=42), ecal, ical, OSLO
        )
        self.read = read
        return month, error, lookups

    def titles(self, month, key):
        return sorted(month["events"][index]["title"] for index in month["dates"][key]["events"])

    def test_an_occurrence_moved_out_of_the_view_leaves_its_old_date(self):
        """A weekly event's 27 November occurrence moved to 15 January (a
        detached instance) shows on neither date of the November view. Its
        RECURRENCE-ID is compared with the occurrence as an instant, an all-day
        one by its date, read as libecal's expansion reads the occurrence: a
        TZID through the calendar, and a floating time or a TZID the calendar
        does not know in the default zone. An instance without a start is
        not placed by the expansion, which keeps the master's occurrence. One
        lookup per recurring event, none for a single one."""
        away = written(datetime(2027, 1, 15, 10), "Europe/Oslo")
        floating = when(FakeDateTime(datetime(2026, 11, 27, 10), None))
        own_zone = written(datetime(2026, 11, 27, 10), "Custom UTC+02")
        unknown = (written(datetime(2026, 11, 27, 10), "Nowhere"), written(datetime(2027, 1, 15, 10), "Nowhere"))
        rows = [
            # name, the series' hour (None: all day) and zone, its detached
            # instance (RECURRENCE-ID, own start), whether 27 November keeps it
            ("in the event's zone", 10, OSLO, (written(datetime(2026, 11, 27, 10), "Europe/Oslo"), away), False),
            ("the same instant in UTC", 10, OSLO, (utc(datetime(2026, 11, 27, 9)), away), False),
            ("floating, in the default zone", 10, OSLO, (floating, away), False),
            ("a zone of the calendar's own", 10, PLUS_TWO, (own_zone, away), False),
            ("a zone the calendar does not know", 10, OSLO, unknown, False),
            ("all day", None, OSLO, (when(FakeDate(date(2026, 11, 27))), when(FakeDate(date(2027, 1, 15)))), False),
            ("10:00 in UTC, an hour later", 10, OSLO, (utc(datetime(2026, 11, 27, 10)), away), True),
            ("another date", 10, OSLO, (written(datetime(2026, 12, 25, 10), "Europe/Oslo"), away), True),
            ("an instance without a start", 10, OSLO, (written(datetime(2026, 11, 27, 10), "Europe/Oslo"), None), True),
        ]
        for name, hour, zone, instance, kept in rows:
            with self.subTest(name):
                occurrences = [
                    master("weekly", november(20, hour, zone)),
                    master("weekly", november(27, hour, zone)),
                    single("lunch", november(27, 12)),
                ]
                month, error, lookups = self.fetch_series(occurrences, {"weekly": [instance]})
                self.assertEqual(self.titles(month, "2026-11-20"), ["Weekly"])
                self.assertEqual(self.titles(month, "2026-11-27"), ["Lunch", "Weekly"] if kept else ["Lunch"])
                self.assertEqual(lookups, ["weekly"])
                self.assertEqual((month["state"], month["complete"], error), ("ok", True, ""))

    def test_an_occurrence_edited_in_place_stays(self):
        """An occurrence changed without a new time (renamed) is a detached
        instance whose start is its RECURRENCE-ID, and libecal shows it. It
        stays, also when it still carries the series' rule."""
        same_time = written(datetime(2026, 11, 27, 10), "Europe/Oslo")
        for rule_left in (True, False):
            with self.subTest(rule_left=rule_left):
                renamed = placed(
                    "weekly", november(27, 10), FakeDateTime(datetime(2026, 11, 27, 10), OSLO), "Renamed", rule_left
                )
                occurrences = [master("weekly", november(20, 10)), renamed]
                month, error, lookups = self.fetch_series(occurrences, {"weekly": [(same_time, same_time)]})
                self.assertEqual(self.titles(month, "2026-11-20"), ["Weekly"])
                self.assertEqual(self.titles(month, "2026-11-27"), ["Renamed"])
                self.assertEqual((month["state"], error), ("ok", ""))

    def test_moved_occurrences_stay_where_libecal_placed_them(self):
        """Only one of the master's occurrences can be left behind by a move.
        A detached instance libecal placed stays, also when it kept the
        series' rule and its new start is another moved occurrence's old one."""

        def at(day):
            return written(datetime(2026, 11, day, 10), "Europe/Oslo")

        def from_(day):
            return FakeDateTime(datetime(2026, 11, day, 10), OSLO)

        away = written(datetime(2027, 1, 15, 10), "Europe/Oslo")
        rows = {
            # 20 November moved onto 27 November, whose occurrence moved to
            # January: libecal shows the master's 27 November occurrence and
            # the instance from 20 November on that date.
            "overlapping moves": (
                [master("weekly", november(27, 10)), placed("weekly", november(27, 10), from_(20), "From 20", True)],
                [(at(20), at(27)), (at(27), away)],
                {"2026-11-20": [], "2026-11-27": ["From 20"]},
            ),
            # 20 and 27 November swapped, both instances with the rule.
            "a swap": (
                [
                    placed("weekly", november(20, 10), from_(27), "From 27", True),
                    placed("weekly", november(27, 10), from_(20), "From 20", True),
                ],
                [(at(20), at(27)), (at(27), at(20))],
                {"2026-11-20": ["From 27"], "2026-11-27": ["From 20"]},
            ),
        }
        for name, (occurrences, instances, shown) in rows.items():
            with self.subTest(name):
                month, error, _ = self.fetch_series(occurrences, {"weekly": instances})
                self.assertEqual({key: self.titles(month, key) for key in shown}, shown)
                self.assertEqual((month["state"], month["complete"], error), ("ok", True, ""))

    def test_a_failed_lookup_of_moved_occurrences_is_never_a_full_result(self):
        month, error, lookups = self.fetch_series([master("weekly", november(27, 10))], {}, failing_lookup=True)
        self.assertEqual(lookups, ["weekly"])
        self.assertEqual(error, "unavailable")
        self.assertEqual(self.titles(month, "2026-11-27"), ["Weekly"])
        self.assertEqual(month["dates"]["2026-11-27"]["state"], "partial")
        self.assertFalse(month["complete"])

    def test_lookups_do_not_spend_the_occurrence_budget(self):
        """MAX_OCCURRENCES counts the expansion only: a calendar that uses it
        up exactly is still complete, with each recurring event looked up."""
        away = written(datetime(2027, 1, 15, 10), "Europe/Oslo")
        moved = [(written(datetime(2026, 12, day, 10), "Europe/Oslo"), away) for day in range(1, 10)]
        month, error, lookups = self.fetch_series(
            [master("first", november(20, 10)), master("second", november(20, 12))],
            {"first": moved},
            cancelled=CALENDAR_EVENTS.MAX_OCCURRENCES - 2,
        )
        self.assertEqual(lookups, ["first", "second"])
        self.assertEqual(self.titles(month, "2026-11-20"), ["First", "Second"])
        self.assertEqual((month["state"], month["complete"], error), ("ok", True, ""))

    def test_a_lookup_stops_reading_at_its_own_bound(self):
        """A recurring event with more detached instances than
        MAX_LOOKUP_COMPONENTS: reading them stops at that bound, and the dates
        that show the event say they are incomplete; the others stay complete."""
        away = written(datetime(2028, 1, 1, 10), "Europe/Oslo")
        many = [
            (written(datetime(2027, 1, 1) + timedelta(hours=hour), "Europe/Oslo"), away)
            for hour in range(CALENDAR_EVENTS.MAX_LOOKUP_COMPONENTS + 100)
        ]
        month, error, lookups = self.fetch_series(
            [master("weekly", november(20, 10)), single("lunch", november(27, 12))], {"weekly": many}
        )
        self.assertEqual(lookups, ["weekly"])
        self.assertLessEqual(self.read, CALENDAR_EVENTS.MAX_LOOKUP_COMPONENTS)
        self.assertEqual(self.titles(month, "2026-11-20"), ["Weekly"])
        states = [month["dates"][key]["state"] for key in ("2026-11-20", "2026-11-27")]
        self.assertEqual(states, ["partial", "ok"])
        self.assertEqual(error, "")

    def test_once_the_lookup_bound_is_spent_only_unchecked_events_dates_are_incomplete(self):
        """The first event's lookup spends MAX_LOOKUP_COMPONENTS exactly; the
        events after it are not looked up, and only their dates are marked."""
        away = written(datetime(2027, 1, 15, 10), "Europe/Oslo")
        instances = [(written(datetime(2026, 12, day, 10), "Europe/Oslo"), away) for day in (24, 25)]
        occurrences = [
            master("first", november(20, 10)),
            master("second", november(27, 10)),
            single("lunch", november(25, 12)),
            master("third", november(30, 10)),
        ]
        # The first lookup reads the event and its two detached instances.
        with patch.object(CALENDAR_EVENTS, "MAX_LOOKUP_COMPONENTS", 4):
            month, error, lookups = self.fetch_series(occurrences, {"first": instances})
        self.assertEqual(lookups, ["first"])
        states = {day: month["dates"][f"2026-11-{day}"]["state"] for day in ("20", "25", "27", "30")}
        self.assertEqual(states, {"20": "ok", "25": "ok", "27": "partial", "30": "partial"})
        self.assertEqual(self.titles(month, "2026-11-27"), ["Second"])
        self.assertEqual(error, "")

    def test_ical_timezone_maps_iana_keys_only(self):
        lookups = []
        ical = SimpleNamespace(Timezone=SimpleNamespace(get_builtin_timezone=lambda key: lookups.append(key) or key))
        self.assertEqual(CALENDAR_EVENTS.ical_timezone(ical, ZoneInfo("Europe/Oslo")), "Europe/Oslo")
        self.assertIsNone(CALENDAR_EVENTS.ical_timezone(ical, timezone.utc))
        self.assertEqual(lookups, ["Europe/Oslo"])

    def test_real_libical_floating_time_follows_local_zone(self):
        try:
            import gi

            gi.require_version("ICalGLib", "4.0")
            from gi.repository import ICalGLib
        except (ImportError, ValueError):
            self.skipTest("ICalGLib not installed")
        zone = CALENDAR_EVENTS.ical_timezone(ICalGLib, ZoneInfo("Europe/Oslo"))
        floating = ICalGLib.Time.new_from_string("20261030T090000")
        stamp = CALENDAR_EVENTS.unix_timestamp(floating, zone)
        self.assertEqual(datetime.fromtimestamp(stamp, ZoneInfo("Europe/Oslo")).strftime("%H:%M"), "09:00")

    def test_real_libecal_recurrence_id_in_a_zone_of_the_calendar(self):
        """A RECURRENCE-ID written with a TZID libical has no built-in zone
        for is read in the zone the calendar defines, not the default zone."""
        try:
            import gi

            gi.require_version("ECal", "2.0")
            gi.require_version("ICalGLib", "4.0")
            from gi.repository import ECal, ICalGLib
        except (ImportError, ValueError):
            self.skipTest("libecal not installed")
        zone = ICalGLib.Timezone.new()
        zone.set_component(
            ICalGLib.Component.new_from_string(
                "BEGIN:VTIMEZONE\nTZID:Custom UTC+02\nBEGIN:STANDARD\nDTSTART:19700101T000000\n"
                "TZOFFSETFROM:+0200\nTZOFFSETTO:+0200\nEND:STANDARD\nEND:VTIMEZONE"
            )
        )
        moved = ECal.Component.new_from_string(
            "BEGIN:VEVENT\nUID:moved\nDTSTAMP:20261101T000000Z\n"
            "RECURRENCE-ID;TZID=Custom UTC+02:20261127T100000\nDTSTART;TZID=Custom UTC+02:20270115T100000\nEND:VEVENT"
        )
        oslo = ICalGLib.Timezone.get_builtin_timezone("Europe/Oslo")
        # The calendar's resolver (ECal.Client.tzlookup_cb) knows its own zone.
        ecal = SimpleNamespace(
            Client=SimpleNamespace(tzlookup_cb=lambda tzid, _client, _cancellable: {"Custom UTC+02": zone}.get(tzid))
        )
        client = SimpleNamespace(get_default_timezone=lambda: oslo)
        instant = CALENDAR_EVENTS.component_time(moved.get_recurid().get_datetime(), client, oslo, ecal)
        self.assertEqual(datetime.fromtimestamp(instant, timezone.utc), datetime(2026, 11, 27, 8, tzinfo=timezone.utc))

    def test_real_evolution_leaves_out_only_occurrences_moved_away(self):
        """The worker's November view on a private evolution-data-server (its
        own bus from dbus-run-session, a temporary HOME) with MOVED_CALENDAR:
        the occurrences moved out of the view are gone, the instances moved
        into it stay, and the month is complete.

        It rests on libecal: the master's occurrences carry their start as
        RECURRENCE-ID and a detached instance its own, the lookup by UID
        returns every detached instance, and ECal.Client.tzlookup_cb gives
        None for an unknown TZID. Were one of these to change, an occurrence
        moved away would show, one moved in would vanish, or the calendar
        would fail.
        """
        try:
            import gi

            gi.require_version("ECal", "2.0")
            gi.require_version("EDataServer", "1.2")
            gi.require_version("ICalGLib", "4.0")
        except (ImportError, ValueError):
            self.skipTest("Evolution Data Server not installed")
        services = [
            service
            for folder in ("/usr/share", "/usr/local/share")
            for service in Path(folder, "dbus-1", "services").glob("org.gnome.evolution.dataserver.Calendar*.service")
        ]
        if not services or shutil.which("dbus-run-session") is None:
            self.skipTest("no Evolution calendar service or dbus-run-session")
        kit = os.environ.get("FOAMY_KIT", Path.home() / "GitHub/Personal/foamy-kit")
        hostenv_path = Path(kit, "preview", "hostenv.py")
        if not hostenv_path.is_file():
            self.skipTest("no foamy-kit checkout (FOAMY_KIT) for its hostenv.ProcessGroup")
        spec = importlib.util.spec_from_file_location("hostenv", hostenv_path)
        hostenv = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(hostenv)
        with TemporaryDirectory() as directory:
            base = Path(directory)
            calendar = base / "data" / "evolution" / "calendar" / "system"
            calendar.mkdir(parents=True)
            (calendar / "calendar.ics").write_text(MOVED_CALENDAR)
            for name in ("home", "config", "cache", "state"):
                (base / name).mkdir()
            (base / "runtime").mkdir(mode=0o700)
            # Nothing of the session reaches EDS: its own HOME and XDG dirs,
            # settings in memory, no system bus; dbus-run-session gives it a
            # bus of its own. MALLOC_ARENA_MAX as the bridge starts the worker.
            env = {
                "PATH": "/usr/bin:/bin",
                "HOME": str(base / "home"),
                "XDG_CONFIG_HOME": str(base / "config"),
                "XDG_DATA_HOME": str(base / "data"),
                "XDG_CACHE_HOME": str(base / "cache"),
                "XDG_STATE_HOME": str(base / "state"),
                "XDG_RUNTIME_DIR": str(base / "runtime"),
                "GSETTINGS_BACKEND": "memory",
                "GIO_USE_VFS": "local",
                "GIO_USE_NETWORK_MONITOR": "base",
                "DBUS_SYSTEM_BUS_ADDRESS": f"unix:path={base}/no-system-bus",
                "LANG": "C.UTF-8",
                "TZ": "Europe/Oslo",
                "MALLOC_ARENA_MAX": "2",
            }
            command = ["dbus-run-session", "--", sys.executable, "-I", str(MODULE_PATH), "--worker"]
            command += ["--range-start", "2026-10-26", "--range-end", "2026-12-07"]
            output = base / "month.json"
            # The bus and the EDS services it starts share the group, which
            # stop() ends when the block is left.
            with (
                output.open("wb") as stdout,
                hostenv.ProcessGroup(command, env=env, stdout=stdout, stderr=subprocess.DEVNULL) as worker,
            ):
                status = worker.wait(CALENDAR_EVENTS.WORKER_SECONDS)
            raw = output.read_bytes()
        self.assertEqual(status, 0)
        month = json.loads(raw)
        self.assertTrue(CALENDAR_EVENTS.valid_payload(month))
        shown = {key: self.titles(month, key) for key in ("2026-11-20", "2026-11-27")}
        expected = {
            "2026-11-20": ["All day", "Swap from 27 Nov", "Unknown zone", "Weekly"],
            "2026-11-27": ["Overlap from 20 Nov", "Swap from 20 Nov"],
        }
        self.assertEqual(shown, expected)
        self.assertEqual((month["state"], month["complete"]), ("ok", True))

    def test_local_timezone_accepts_paths_names_and_bad_values(self):
        oslo = Path("/usr/share/zoneinfo/Europe/Oslo")
        if not oslo.exists():
            self.skipTest("zoneinfo not installed")
        cases = {
            ":Europe/Oslo": "Europe/Oslo",
            "Europe/Oslo": "Europe/Oslo",
            ":" + str(oslo): "Europe/Oslo",
            str(oslo): "Europe/Oslo",
        }
        for value, key in cases.items():
            with patch.dict("os.environ", {"TZ": value}):
                self.assertEqual(CALENDAR_EVENTS.local_timezone().key, key, value)
        localtime = (
            CALENDAR_EVENTS.zone_from_file(Path("/etc/localtime")).key if Path("/etc/localtime").exists() else "UTC"
        )
        for value in (
            ":/etc/localtime",
            "/etc/localtime",
            "Not/AZone",
            "CET-1CEST,M3.5.0,M10.5.0/3",
            ":/nonexistent/zone",
        ):
            with patch.dict("os.environ", {"TZ": value}):
                zone = CALENDAR_EVENTS.local_timezone()
                # Unusable values fall back to /etc/localtime instead of raising.
                self.assertEqual(zone.key, localtime, value)
        with patch.dict("os.environ", {"TZ": ":/etc/localtime"}), TemporaryDirectory() as directory:
            # read_cache must not raise even with an unusual TZ.
            self.assertEqual(CALENDAR_EVENTS.read_cache(Path(directory) / "missing.json")["views"], {})

    def test_cached_reads_never_rewrite_fresher_data(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "agenda.json"
            older = self.payload(start=date(2026, 8, 24))
            newer = self.payload(start=date(2026, 8, 25))
            CALENDAR_EVENTS.store_view(older, path)
            CALENDAR_EVENTS.store_view(newer, path)
            stamp = path.stat().st_mtime_ns
            # Already most recent: no write at all.
            self.assertFalse(CALENDAR_EVENTS.touch_view(date(2026, 8, 25), date(2026, 10, 6), path))
            self.assertEqual(path.stat().st_mtime_ns, stamp)
            # Another bridge stores fresher data for the newer key after touch_view's
            # first read, while touch_view waits for the lock. The touch must not
            # write back its stale snapshot.
            fresh_newer = self.payload(
                start=date(2026, 8, 25), events=[self.event(startDate="2026-08-25", endDate="2026-08-26")]
            )
            fresh_newer["updatedAt"] = 999999
            original_lock = CALENDAR_EVENTS.cache_lock
            entered = []

            @contextlib.contextmanager
            def other_bridge_first(lock_path):
                # The nested store_view enters this wrapper again and goes
                # straight to the real lock.
                if not entered:
                    entered.append(True)
                    self.assertTrue(CALENDAR_EVENTS.store_view(fresh_newer, lock_path))
                with original_lock(lock_path) as locked:
                    yield locked

            with patch.object(CALENDAR_EVENTS, "cache_lock", other_bridge_first):
                self.assertTrue(CALENDAR_EVENTS.touch_view(date(2026, 8, 24), date(2026, 10, 5), path))
            views = CALENDAR_EVENTS.read_cache(path)["views"]
            self.assertEqual(views["month:2026-08-25:2026-10-06"]["updatedAt"], 999999)
            self.assertEqual(list(views)[-1], "month:2026-08-24:2026-10-05")

    def test_cache_writes_wait_for_the_lock_and_give_up_when_held(self):
        import fcntl
        import os

        with TemporaryDirectory() as directory:
            path = Path(directory) / "agenda.json"
            path.parent.mkdir(exist_ok=True)
            holder = os.open(path.parent / ".agenda.lock", os.O_RDWR | os.O_CREAT, 0o600)
            try:
                fcntl.flock(holder, fcntl.LOCK_EX)
                with patch.object(CALENDAR_EVENTS, "CACHE_LOCK_SECONDS", 0.1):
                    began = time.monotonic()
                    self.assertFalse(CALENDAR_EVENTS.store_view(self.payload(), path))
                    self.assertLess(time.monotonic() - began, 1.0)
                self.assertFalse(path.exists())
            finally:
                os.close(holder)
            self.assertTrue(CALENDAR_EVENTS.store_view(self.payload(), path))

    def test_writing_the_cache_deletes_legacy_versions(self):
        with TemporaryDirectory() as directory:
            folder = Path(directory)
            for name in ("agenda-v1.json", "agenda-v2.json", "notes.json"):
                (folder / name).write_text("{}")
            path = folder / f"agenda-v{CALENDAR_EVENTS.CACHE_VERSION}.json"
            self.assertTrue(CALENDAR_EVENTS.store_view(self.payload(), path))
            self.assertEqual(
                sorted(p.name for p in folder.iterdir() if not p.name.startswith(".")), ["agenda-v3.json", "notes.json"]
            )


if __name__ == "__main__":
    unittest.main()
