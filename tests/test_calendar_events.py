#!/usr/bin/env python3

import importlib.util
import json
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

    def payload(self, state="ok", kind="day", start=date(2026, 8, 24)):
        result = CALENDAR_EVENTS.base_payload(kind, start, start + timedelta(days=1 if kind == "day" else 42), state)
        result["updatedAt"] = 123456
        return result

    def event(self, **values):
        result = {"id": "calendar:event:1", "title": "Planning", "location": "Room", "calendar": "Work", "color": "", "allDay": True, "start": 0, "end": 0, "startDate": "2026-08-24", "endDate": "2026-08-25"}
        result.update(values)
        return result

    def fetch(self, count, kind="day", title="Planning", cancelled=False, span=1):
        class Occurrence:
            def __init__(self, day): self.day = day
            def is_date(self): return True
            def get_year(self): return self.day.year
            def get_month(self): return self.day.month
            def get_day(self): return self.day.day
        start = datetime(2026, 8, 24, tzinfo=timezone.utc)
        component = SimpleNamespace(get_status=lambda: "cancelled" if cancelled else "ok", get_summary=lambda: title, get_location=lambda: "Room", get_uid=lambda: "event")
        self.visited = 0
        def generate(_start, _end, _cancel, callback, _data):
            for _ in range(count):
                self.visited += 1
                if not callback(component, Occurrence(start.date()), Occurrence(start.date() + timedelta(days=span)), None, None):
                    break
        client = SimpleNamespace(generate_instances_sync=generate)
        ecal = SimpleNamespace(Client=SimpleNamespace(connect_sync=lambda *_: client), ClientSourceType=SimpleNamespace(EVENTS=1))
        ical = SimpleNamespace(PropertyStatus=SimpleNamespace(CANCELLED="cancelled"))
        return CALENDAR_EVENTS.fetch_source_events(SimpleNamespace(get_uid=lambda: "calendar"), "Work", "#aabbcc", start, start + timedelta(days=1 if kind == "day" else 42), ecal, ical, kind)

    def test_dense_day_stops_and_retains_fixed_number(self):
        for count in (2000, 200000):
            events, error = self.fetch(count)
            self.assertEqual(len(events), CALENDAR_EVENTS.MAX_EVENTS)
            self.assertEqual(self.visited, CALENDAR_EVENTS.MAX_EVENTS + 1)
            self.assertEqual(error, "limited")

    def test_huge_unicode_fields_are_bounded_before_normalizing(self):
        events, error = self.fetch(1, title="🙂 \n" * 100000)
        self.assertLessEqual(len(events[0]["title"]), 256)
        self.assertTrue(events[0]["title"].endswith("…"))
        self.assertEqual(error, "limited")
        payload = self.payload()
        payload["events"] = [self.event(title="🙂" * 256, location="🙂" * 128, calendar="🙂" * 80) for _ in range(100)]
        self.assertTrue(CALENDAR_EVENTS.valid_payload(payload))
        self.assertLess(len(CALENDAR_EVENTS.encode(payload)), CALENDAR_EVENTS.MAX_RESPONSE_BYTES)

    def test_grid_does_not_read_titles_and_bounds_occurrence_work(self):
        class Unreadable:
            def __len__(self): raise AssertionError("grid read summary")
        markers, error = self.fetch(200000, "grid", title=Unreadable())
        self.assertEqual(len(markers), 1)
        self.assertEqual(self.visited, CALENDAR_EVENTS.MAX_OCCURRENCES + 1)
        self.assertEqual(error, "limited")

    def test_full_grid_source_can_finish_early_without_partial(self):
        markers, error = self.fetch(200000, "grid", span=42)
        self.assertEqual(len(markers), 42)
        self.assertEqual(self.visited, 1)
        self.assertEqual(error, "")

    def test_cancelled_occurrences_still_have_a_work_budget(self):
        events, error = self.fetch(200000, cancelled=True)
        self.assertEqual(events, [])
        self.assertEqual(error, "limited")
        self.assertEqual(self.visited, CALENDAR_EVENTS.MAX_OCCURRENCES + 1)

    def test_spanning_and_exclusive_all_day_end(self):
        event = self.event(endDate="2026-08-26")
        self.assertTrue(CALENDAR_EVENTS.overlaps(event, date(2026, 8, 25), timezone.utc))
        self.assertFalse(CALENDAR_EVENTS.overlaps(event, date(2026, 8, 26), timezone.utc))

    def test_dst_day_uses_next_local_midnight(self):
        zone = ZoneInfo("Europe/Oslo")
        event = self.event(allDay=False, start=int(datetime(2026, 3, 30, 0, 30, tzinfo=zone).timestamp()), end=int(datetime(2026, 3, 30, 1, tzinfo=zone).timestamp()))
        self.assertFalse(CALENDAR_EVENTS.overlaps(event, date(2026, 3, 29), zone))
        self.assertTrue(CALENDAR_EVENTS.overlaps(event, date(2026, 3, 30), zone))
        instant = self.event(allDay=False, start=int(datetime(2026, 10, 25, 23, 30, tzinfo=zone).timestamp()), end=0)
        self.assertTrue(CALENDAR_EVENTS.overlaps(instant, date(2026, 10, 25), zone))

    def test_cache_round_trip_and_partial_keeps_completeness(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "agenda.json"
            payload = self.payload("partial")
            payload["events"] = [self.event()]
            self.assertTrue(CALENDAR_EVENTS.store_view(payload, path))
            cached = CALENDAR_EVENTS.cached_view("day", date(2026, 8, 24), date(2026, 8, 25), path)
            self.assertEqual(cached["state"], "partial")
            self.assertTrue(cached["cached"])
            self.assertFalse(cached["complete"])
            self.assertEqual(cached["updatedAt"], 123456)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_failed_refresh_preserves_good_data_and_persists_warning(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "agenda.json"
            good = self.payload()
            good["events"] = [self.event()]
            CALENDAR_EVENTS.store_view(good, path)
            for fresh in (None, self.payload("partial")):
                with patch.object(CALENDAR_EVENTS, "run_bounded_worker", return_value=fresh):
                    result = CALENDAR_EVENTS.refreshed_view("day", date(2026, 8, 24), date(2026, 8, 25), path)
                self.assertEqual(result["events"], good["events"])
                self.assertEqual(result["state"], "partial")
                self.assertTrue(result["cached"])
                self.assertTrue(result["complete"])
                cached = CALENDAR_EVENTS.cached_view("day", date(2026, 8, 24), date(2026, 8, 25), path)
                self.assertEqual(cached["state"], "partial")
            with patch.object(CALENDAR_EVENTS, "run_bounded_worker", return_value=good):
                recovered = CALENDAR_EVENTS.refreshed_view("day", date(2026, 8, 24), date(2026, 8, 25), path)
            self.assertEqual(recovered["state"], "ok")
            self.assertFalse(recovered["cached"])

    def test_cache_rejects_oversized_corrupt_and_old_files(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "agenda.json"
            for raw in (b" " * (CALENDAR_EVENTS.MAX_CACHE_BYTES + 1), b'{"version":1,"dates":{}}', b"[", b"null", b"[" * 2000):
                path.write_bytes(raw)
                self.assertEqual(CALENDAR_EVENTS.read_cache(path)["views"], {})

    def test_cache_evicts_by_bytes_and_entry_count(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "agenda.json"
            for offset in range(70):
                payload = self.payload(start=date(2026, 1, 1) + timedelta(days=offset))
                payload["events"] = [self.event(title="🙂" * 256) for _ in range(100)]
                CALENDAR_EVENTS.store_view(payload, path)
                self.assertLessEqual(path.stat().st_size, CALENDAR_EVENTS.MAX_CACHE_BYTES)
            views = CALENDAR_EVENTS.read_cache(path)["views"]
            self.assertLessEqual(len(views), CALENDAR_EVENTS.MAX_CACHE_ENTRIES)
            self.assertNotIn("day:2026-01-01:2026-01-02", views)
            self.assertEqual(list(views.values())[-1]["date"], payload["date"])

    def test_worker_reader_rejects_flood_without_newline_stderr_and_timeout(self):
        scripts = ["import os; os.write(1, b'x' * 1048576)", "import os; os.write(2, b'x' * 1048576); os.write(1, b'{}')", "import time; time.sleep(10)", "print('[' * 2000)"]
        for script in scripts:
            started = time.monotonic()
            result = CALENDAR_EVENTS.run_bounded_worker([sys.executable, "-c", script], timeout=0.2)
            self.assertIsNone(result)
            self.assertLess(time.monotonic() - started, 2)

    def test_worker_reader_accepts_valid_payload(self):
        payload = self.payload()
        result = CALENDAR_EVENTS.run_bounded_worker([sys.executable, "-c", "print(" + repr(json.dumps(payload)) + ")"])
        self.assertEqual(result, payload)

    def test_worker_reader_rejects_malformed_schema(self):
        for mutate in (lambda p: p.update(events=[{}]), lambda p: p.update(updatedAt="now"), lambda p: p.update(events=[self.event(title="x" * 257)])):
            payload = self.payload()
            mutate(payload)
            self.assertFalse(CALENDAR_EVENTS.valid_payload(payload))

    def test_missing_cache_and_failed_live_view_stay_unavailable(self):
        with TemporaryDirectory() as directory:
            with patch.object(CALENDAR_EVENTS, "run_bounded_worker", return_value=None):
                result = CALENDAR_EVENTS.refreshed_view("day", date(2026, 8, 24), date(2026, 8, 25), Path(directory) / "cache.json")
        self.assertEqual(result["state"], "error")
        self.assertFalse(result["complete"])

    def test_fresh_cached_navigation_does_not_start_a_worker(self):
        import os
        payload = self.payload()
        payload["updatedAt"] = int(time.time())
        with TemporaryDirectory() as directory:
            path = Path(directory) / "foamy-clock" / "agenda-v2.json"
            CALENDAR_EVENTS.store_view(payload, path)
            with patch.dict(os.environ, {"XDG_CACHE_HOME": directory}), patch.object(sys, "argv", [str(MODULE_PATH), "--date", "2026-08-24", "--max-age", "1800"]), patch.object(CALENDAR_EVENTS, "run_bounded_worker", side_effect=AssertionError("unnecessary worker")), patch("builtins.print") as output:
                self.assertEqual(CALENDAR_EVENTS.main(), 0)
            result = json.loads(output.call_args.args[0])
            self.assertTrue(result["cached"])
            self.assertEqual(result["state"], "ok")

    def test_worker_deadline_reaps_process(self):
        with TemporaryDirectory() as directory:
            pid_path = Path(directory) / "pid"
            script = "import os,time; open(" + repr(str(pid_path)) + ", 'w').write(str(os.getpid())); time.sleep(10)"
            self.assertIsNone(CALENDAR_EVENTS.run_bounded_worker([sys.executable, "-c", script], timeout=0.3))
            pid = int(pid_path.read_text())
            self.assertFalse(Path(f"/proc/{pid}").exists())

    def test_source_count_concurrency_and_merged_events_are_bounded(self):
        import threading
        extension = SimpleNamespace(get_selected=lambda: True, get_color=lambda: "")
        sources = [SimpleNamespace(get_enabled=lambda: True, get_extension=lambda _: extension, get_display_name=lambda: "Work") for _ in range(40)]
        registry = SimpleNamespace(list_sources=lambda _: sources)
        data_server = SimpleNamespace(SourceRegistry=SimpleNamespace(new_sync=lambda _: registry), SOURCE_EXTENSION_CALENDAR="calendar")
        repository = SimpleNamespace(ECal=object(), EDataServer=data_server, ICalGLib=object())
        active = peak = calls = 0
        lock = threading.Lock()
        def fetch(*_args):
            nonlocal active, peak, calls
            with lock:
                active += 1
                calls += 1
                peak = max(peak, active)
            time.sleep(0.002)
            with lock:
                active -= 1
            return [self.event() for _ in range(100)], ""
        with patch.dict(sys.modules, {"gi": SimpleNamespace(require_version=lambda *_: None), "gi.repository": repository}), patch.object(CALENDAR_EVENTS, "fetch_source_events", side_effect=fetch):
            result = CALENDAR_EVENTS.load_view("day", date(2026, 8, 24), date(2026, 8, 25))
        self.assertEqual(calls, 32)
        self.assertLessEqual(peak, 2)
        self.assertEqual(len(result["events"]), 100)
        self.assertEqual(result["state"], "partial")
        self.assertFalse(result["complete"])

    def test_worker_memory_limit_turns_large_allocation_into_failure(self):
        script = (
            "import importlib.util,sys; "
            "s=importlib.util.spec_from_file_location('calendar_events', " + repr(str(MODULE_PATH)) + "); "
            "m=importlib.util.module_from_spec(s); s.loader.exec_module(m); "
            "m.load_view=lambda *_: bytearray(1024**3); "
            "sys.argv=['calendar-events.py','--worker','day','--date','2026-08-24','--range-end','2026-08-25']; "
            "m.main()"
        )
        result = CALENDAR_EVENTS.run_bounded_worker([sys.executable, "-c", script])
        self.assertIsNotNone(result)
        self.assertEqual(result["state"], "error")
        self.assertFalse(result["complete"])

    def test_cached_cli_returns_day_before_grid(self):
        with TemporaryDirectory() as directory:
            import os
            output = subprocess.check_output([sys.executable, str(MODULE_PATH), "--cached", "--date", "2026-08-24", "--range-start", "2026-08-01", "--range-end", "2026-09-12"], env={**os.environ, "XDG_CACHE_HOME": directory})
            lines = [json.loads(line) for line in output.splitlines()]
            self.assertEqual([item["kind"] for item in lines], ["day", "grid"])
            self.assertTrue(all(CALENDAR_EVENTS.valid_payload(item) for item in lines))


if __name__ == "__main__":
    unittest.main()
