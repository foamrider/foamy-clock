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
        component = SimpleNamespace(get_status=lambda: "cancelled" if cancelled else "ok", get_summary=lambda: title, get_location=lambda: "Room", get_uid=lambda: f"event-{self.visited}")
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

    def test_control_characters_cannot_expand_shell_messages(self):
        events, _ = self.fetch(100, title="a\x01" * 128)
        self.assertTrue(all("\x01" not in event["title"] for event in events))
        payload = self.payload()
        payload["events"] = events
        self.assertTrue(CALENDAR_EVENTS.valid_payload(payload))
        self.assertLess(len(CALENDAR_EVENTS.encode(payload)), CALENDAR_EVENTS.MAX_RESPONSE_BYTES)

    def test_month_occurrence_work_is_bounded(self):
        month, error = self.fetch(200000, "month")
        self.assertEqual(len(month["events"]), 100)
        self.assertEqual(self.visited, CALENDAR_EVENTS.MAX_OCCURRENCES + 1)
        self.assertEqual(month["state"], "partial")
        self.assertTrue(CALENDAR_EVENTS.valid_payload(month))

    def test_spanning_event_is_stored_once_for_all_dates(self):
        month, error = self.fetch(1, "month", span=42)
        self.assertEqual(len(month["events"]), 1)
        self.assertEqual(len(month["dates"]), 42)
        self.assertTrue(all(day["events"] == [0] for day in month["dates"].values()))
        self.assertEqual(month["state"], "ok")
        self.assertEqual(error, "")

    def test_busy_day_does_not_mark_other_days_incomplete(self):
        month, _ = self.fetch(101, "month")
        self.assertEqual(month["dates"]["2026-08-24"]["state"], "partial")
        self.assertEqual(month["dates"]["2026-08-25"]["state"], "ok")
        self.assertEqual(month["dates"]["2026-08-25"]["events"], [])

    def test_month_has_total_event_and_encoded_byte_budgets(self):
        builder = CALENDAR_EVENTS.MonthBuilder(date(2026, 8, 1), date(2026, 9, 12))
        keys = list(builder.payload["dates"])
        for i in range(4200):
            builder.add(self.event(id=f"event-{i}", title="🙂" * 256, location="🙂" * 128, calendar="🙂" * 80), [keys[i % 42]])
        month = builder.finish()
        self.assertLessEqual(len(month["events"]), CALENDAR_EVENTS.MAX_MONTH_EVENTS)
        self.assertLessEqual(len(CALENDAR_EVENTS.encode(month)), CALENDAR_EVENTS.MAX_MONTH_BYTES)
        self.assertEqual(month["state"], "partial")
        self.assertTrue(CALENDAR_EVENTS.valid_payload(month))
        with patch("builtins.print") as output:
            CALENDAR_EVENTS.emit_view(month)
        lines = [call.args[0].encode() for call in output.call_args_list]
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
                    builder.add(self.event(id=f"event-{i}", title="🙂" * 256, location="🙂" * 128, calendar="🙂" * 80), [keys[i % 42]])
                CALENDAR_EVENTS.store_view(builder.finish(), path)
                self.assertLessEqual(path.stat().st_size, CALENDAR_EVENTS.MAX_CACHE_BYTES)
                if month == 4:
                    self.assertEqual(len(CALENDAR_EVENTS.read_cache(path)["views"]), 4)
            views = CALENDAR_EVENTS.read_cache(path)["views"]
            self.assertLess(len(views), 6)
            self.assertEqual(list(views.values())[-1]["date"], "2026-06-01")

    def test_invalid_month_references_and_size_are_rejected(self):
        month = CALENDAR_EVENTS.base_payload("month", date(2026, 8, 1), date(2026, 9, 12), "ok")
        month["dates"]["2026-08-01"]["events"] = [0]
        self.assertFalse(CALENDAR_EVENTS.valid_payload(month))
        month["events"] = [self.event()]
        self.assertTrue(CALENDAR_EVENTS.valid_payload(month))
        month["dates"]["2026-08-01"]["events"] = [0, 0]
        self.assertFalse(CALENDAR_EVENTS.valid_payload(month))
        flood = "import os; os.write(1, b'x' * (3 * 1024 * 1024))"
        self.assertIsNone(CALENDAR_EVENTS.run_bounded_worker([sys.executable, "-c", flood], max_bytes=CALENDAR_EVENTS.MAX_MONTH_BYTES))

    def test_failed_dates_keep_cached_events_while_good_dates_update(self):
        start, end = date(2026, 8, 24), date(2026, 8, 26)
        old = CALENDAR_EVENTS.MonthBuilder(start, end)
        old.add(self.event(), ["2026-08-24", "2026-08-25"])
        cached = old.finish()
        for day in cached["dates"].values(): day["updatedAt"] = 100
        fresh = CALENDAR_EVENTS.base_payload("month", start, end, "ok")
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

    def test_month_cache_survives_restart_and_worker_failure(self):
        start, end = date(2026, 8, 24), date(2026, 10, 5)
        builder = CALENDAR_EVENTS.MonthBuilder(start, end)
        builder.add(self.event(), ["2026-08-24"])
        good = builder.finish()
        with TemporaryDirectory() as directory:
            path = Path(directory) / "cache.json"
            CALENDAR_EVENTS.store_view(good, path)
            with patch.object(CALENDAR_EVENTS, "run_bounded_worker", return_value=None):
                result = CALENDAR_EVENTS.refreshed_view("month", start, end, path)
            self.assertEqual(len(result["events"]), 1)
            self.assertEqual(result["dates"]["2026-08-24"]["events"], [0])
            self.assertEqual(result["state"], "partial")
            recovered = CALENDAR_EVENTS.cached_view("month", start, end, path)
            self.assertEqual(recovered["dates"], result["dates"])
            self.assertTrue(CALENDAR_EVENTS.valid_payload(recovered))

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
            path = Path(directory) / "foamy-clock" / "agenda-v3.json"
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

    def test_cached_cli_emits_atomic_month_transaction(self):
        with TemporaryDirectory() as directory:
            import os
            output = subprocess.check_output([sys.executable, str(MODULE_PATH), "--cached", "--date", "2026-08-24", "--range-start", "2026-08-01", "--range-end", "2026-09-12"], env={**os.environ, "XDG_CACHE_HOME": directory})
            lines = [json.loads(line) for line in output.splitlines()]
            self.assertEqual([item["kind"] for item in lines], ["month-start", "month-end"])
            self.assertEqual(len(lines[0]["dates"]), 42)
            self.assertEqual(lines[0]["state"], "missing")

    def test_cache_only_refresh_persists_without_shell_output(self):
        start = date(2026, 8, 24)
        month = self.payload(kind="month", start=start)
        month["events"] = [self.event()]
        month["dates"][start.isoformat()]["events"] = [0]
        with TemporaryDirectory() as directory:
            path = Path(directory) / "agenda.json"
            with patch.object(sys, "argv", ["calendar-events.py", "--cache-only", "--range-start", str(start), "--range-end", str(start + timedelta(days=42))]), patch.object(CALENDAR_EVENTS, "default_cache_path", return_value=path), patch.object(CALENDAR_EVENTS, "run_bounded_worker", return_value=month) as worker, patch.object(CALENDAR_EVENTS, "emit_view") as output:
                self.assertEqual(CALENDAR_EVENTS.main(), 0)
                worker.assert_called_once()
                output.assert_not_called()
            cached = CALENDAR_EVENTS.cached_view("month", start, start + timedelta(days=42), path)
            self.assertEqual(cached["events"], month["events"])
            self.assertEqual(cached["state"], "ok")

            # A restart reuses fresh prefetched data without an Exchange query.
            cached["updatedAt"] = int(time.time())
            CALENDAR_EVENTS.store_view(cached, path)
            with patch.object(sys, "argv", ["calendar-events.py", "--cache-only", "--max-age", "1800", "--range-start", str(start), "--range-end", str(start + timedelta(days=42))]), patch.object(CALENDAR_EVENTS, "default_cache_path", return_value=path), patch.object(CALENDAR_EVENTS, "run_bounded_worker", side_effect=AssertionError("unnecessary worker")), patch.object(CALENDAR_EVENTS, "emit_view") as output:
                self.assertEqual(CALENDAR_EVENTS.main(), 0)
                output.assert_not_called()


if __name__ == "__main__":
    unittest.main()
