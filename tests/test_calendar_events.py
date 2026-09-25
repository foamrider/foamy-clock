#!/usr/bin/env python3

import importlib.util
import json
from datetime import datetime, timezone
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "calendar-events.py"
SPEC = importlib.util.spec_from_file_location("calendar_events", MODULE_PATH)
assert SPEC and SPEC.loader
CALENDAR_EVENTS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CALENDAR_EVENTS)


class CalendarEventsTest(unittest.TestCase):
    def test_normalize_hex_color(self) -> None:
        self.assertEqual(CALENDAR_EVENTS.normalize_color("#83D754"), "#83d754")

    def test_normalize_rgb_color(self) -> None:
        self.assertEqual(
            CALENDAR_EVENTS.normalize_color("rgb(28,113,216)"), "#1c71d8"
        )

    def test_invalid_color_uses_theme_accent(self) -> None:
        self.assertEqual(
            CALENDAR_EVENTS.normalize_color("not-a-color"),
            CALENDAR_EVENTS.DEFAULT_COLOR,
        )

    def test_clean_text_flattens_calendar_fields(self) -> None:
        self.assertEqual(
            CALENDAR_EVENTS.clean_text("  Planning\n  room  "), "Planning room"
        )

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

        self.assertEqual(
            CALENDAR_EVENTS.unix_timestamp(occurrence, fallback_timezone), 123
        )
        self.assertIs(occurrence.converted_with, occurrence_timezone)

    def test_timestamp_uses_client_timezone_as_fallback(self) -> None:
        fallback_timezone = object()

        class Occurrence:
            def get_timezone(self):
                return None

            def as_timet_with_zone(self, timezone):
                self.converted_with = timezone
                return 456

        occurrence = Occurrence()

        self.assertEqual(
            CALENDAR_EVENTS.unix_timestamp(occurrence, fallback_timezone), 456
        )
        self.assertIs(occurrence.converted_with, fallback_timezone)

    def test_range_payloads_split_spanning_events_across_dates(self) -> None:
        timed_start = int(datetime(2026, 8, 24, 23, 30, tzinfo=timezone.utc).timestamp())
        timed_end = int(datetime(2026, 8, 25, 0, 30, tzinfo=timezone.utc).timestamp())
        events = [
            {
                "id": "timed",
                "title": "Timed",
                "allDay": False,
                "start": timed_start,
                "end": timed_end,
                "startDate": "",
                "endDate": "",
            },
            {
                "id": "all-day",
                "title": "All day",
                "allDay": True,
                "start": 0,
                "end": 0,
                "startDate": "2026-08-25",
                "endDate": "2026-08-27",
            },
        ]

        payloads = CALENDAR_EVENTS.build_date_payloads(
            CALENDAR_EVENTS.date(2026, 8, 24),
            CALENDAR_EVENTS.date(2026, 8, 27),
            events,
            2,
            0,
            123456,
            timezone.utc,
        )

        self.assertEqual(
            [[event["id"] for event in payload["events"]] for payload in payloads],
            [["timed"], ["all-day", "timed"], ["all-day"]],
        )

    def test_cache_round_trip_keeps_original_update_time(self) -> None:
        payload = {
            "state": "ok",
            "message": "",
            "date": "2026-08-24",
            "events": [{"id": "calendar:event:1", "title": "Planning"}],
            "selectedCalendars": 2,
            "failedCalendars": 0,
            "updatedAt": 123456,
            "cached": False,
        }

        with TemporaryDirectory() as directory:
            cache_path = Path(directory) / "agenda.json"
            self.assertTrue(CALENDAR_EVENTS.store_date_payload(payload, cache_path))
            cached = CALENDAR_EVENTS.cached_date_payload(
                CALENDAR_EVENTS.date(2026, 8, 24), cache_path
            )

            self.assertEqual(cached["state"], "cached")
            self.assertEqual(cached["updatedAt"], 123456)
            self.assertEqual(cached["events"], payload["events"])
            self.assertEqual(cache_path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(cache_path.read_text())["version"], 1)

    def test_error_payload_does_not_replace_last_good_cache(self) -> None:
        good_payload = {
            "state": "ok",
            "message": "",
            "date": "2026-08-24",
            "events": [{"id": "calendar:event:1"}],
            "selectedCalendars": 1,
            "failedCalendars": 0,
            "updatedAt": 123456,
            "cached": False,
        }

        with TemporaryDirectory() as directory:
            cache_path = Path(directory) / "agenda.json"
            CALENDAR_EVENTS.store_date_payload(good_payload, cache_path)
            self.assertFalse(
                CALENDAR_EVENTS.store_date_payload(
                    CALENDAR_EVENTS.error_payload(CALENDAR_EVENTS.date(2026, 8, 24)),
                    cache_path,
                )
            )

            cached = CALENDAR_EVENTS.cached_date_payload(
                CALENDAR_EVENTS.date(2026, 8, 24), cache_path
            )
            self.assertEqual(cached["events"], good_payload["events"])
            self.assertEqual(cached["updatedAt"], 123456)

    def test_range_cache_writes_all_good_dates_atomically(self) -> None:
        payloads = [
            {
                "state": "ok",
                "message": "",
                "date": f"2026-08-{day:02d}",
                "events": [],
                "selectedCalendars": 2,
                "failedCalendars": 0,
                "updatedAt": 123456,
                "cached": False,
            }
            for day in (24, 25, 26)
        ]

        with TemporaryDirectory() as directory:
            cache_path = Path(directory) / "agenda.json"
            self.assertTrue(
                CALENDAR_EVENTS.store_date_payloads(payloads, cache_path)
            )
            cached_dates = json.loads(cache_path.read_text())["dates"]

        self.assertEqual(sorted(cached_dates), [payload["date"] for payload in payloads])

    def test_missing_cache_is_explicit(self) -> None:
        with TemporaryDirectory() as directory:
            cached = CALENDAR_EVENTS.cached_date_payload(
                CALENDAR_EVENTS.date(2026, 8, 25),
                Path(directory) / "missing.json",
            )

        self.assertEqual(cached["state"], "missing")
        self.assertEqual(cached["date"], "2026-08-25")
        self.assertEqual(cached["events"], [])


if __name__ == "__main__":
    unittest.main()
