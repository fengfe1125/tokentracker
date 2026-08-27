"""Offline billing cache and quota contract regression tests."""
import io
import json
import math
import multiprocessing
import os
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
from email.utils import formatdate
from pathlib import Path
from urllib.error import HTTPError
from unittest.mock import Mock, patch

from tokentracker import billing, quotas


def _cache_writer(path, key, start):
    billing._disk_path = lambda: path
    start.wait(5)
    for i in range(15):
        billing._disk_store(key, 1_000_000, {"windows": {}, "sequence": i})


class PercentageTest(unittest.TestCase):
    def test_official_utilization_is_already_percent(self):
        for value, expected in [(0, 0), (0.5, 0.5), (1, 1), (45, 45), ("0.5", 0.5)]:
            with self.subTest(value=value):
                self.assertEqual(billing._pct(value), expected)

    def test_invalid_percentages_are_absent(self):
        for value in [None, "bad", math.nan, math.inf, -math.inf]:
            with self.subTest(value=value):
                self.assertIsNone(billing._pct(value))


class QuotaSourceTest(unittest.TestCase):
    def test_stale_is_attached_only_to_official_windows(self):
        config = {"entries": [{"id": "test", "name": "Test", "tool": "test",
                               "official": "claude-oauth", "windows": {
                                   "5h": {"limit_tokens": 100},
                                   "7d": {"limit_tokens": 100}}}]}
        official = {"windows": {"5h": {"pct": 20}}, "_stale_min": 3, "_via": "oauth"}
        with patch.object(quotas, "load_quotas", return_value=config), \
                patch.object(billing, "_cached", return_value=official), \
                patch.object(quotas.db, "window_usage", return_value=45), \
                patch.object(quotas.db, "window_unallocated", return_value=0):
            entry = quotas.compute(None)["entries"][0]
        self.assertEqual([(w["source"], w["stale"]) for w in entry["windows"]],
                         [("official", True), ("local", False)])
        self.assertEqual(entry["via"], "oauth")
        self.assertIn("3 分钟前", entry["note"])

    def test_local_window_reports_but_does_not_count_unallocated_usage(self):
        config = {"entries": [{"id": "test", "name": "Test", "tool": "test",
                               "windows": {"5h": {"limit_tokens": 100}}}]}
        with patch.object(quotas, "load_quotas", return_value=config), \
                patch.object(quotas.db, "window_usage", return_value=45), \
                patch.object(quotas.db, "window_unallocated", return_value=20):
            window = quotas.compute(None)["entries"][0]["windows"][0]
        self.assertEqual(window["used"], 45)
        self.assertEqual(window["pct"], 45)
        self.assertEqual(window["unallocated"], 20)


class HttpBackoffTest(unittest.TestCase):
    def test_http_date_and_non_object_error_bodies_keep_retry_after(self):
        now = 1_000_000
        for header in ("300", formatdate(now + 300, usegmt=True)):
            for body in (b"{}", b"[]", b"not json"):
                with self.subTest(header=header, body=body):
                    error = HTTPError("http://mock.invalid", 429, "limited",
                                      {"Retry-After": header}, io.BytesIO(body))
                    with patch.object(billing.urllib.request, "urlopen", side_effect=error), \
                            patch.object(billing.time, "time", return_value=now):
                        status, data = billing._http_json("http://mock.invalid", {})
                    self.assertEqual(status, 429)
                    self.assertEqual(data.get("_retry_after"), 300)


class KimiReadOnlyTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="tt_kimi_")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name) / ".kimi-code"
        self.path = self.root / "credentials" / "kimi-code.json"
        self.path.parent.mkdir(parents=True)
        self.now = 1_000_000.0
        self.response = {"usage": {"limit": 100, "remaining": 55}}
        for p in [patch.dict(os.environ, {"HOME": temp.name, "KIMI_CODE_HOME": str(self.root)}),
                  patch.object(billing, "_cache", {}),
                  patch.object(billing.time, "time", return_value=self.now),
                  patch.object(billing, "_disk_path", return_value=str(Path(temp.name) / "quota.json"))]:
            p.start()
            self.addCleanup(p.stop)
        http = patch.object(billing, "_http_json", return_value=(200, self.response))
        self.http = http.start()
        self.addCleanup(http.stop)

    def write_credentials(self, **overrides):
        data = {"access_token": "fake-access", "expires_at": self.now + 900, **overrides}
        self.path.write_text(json.dumps(data), encoding="utf-8")
        return self.path.read_bytes(), self.path.stat().st_mtime_ns

    def test_valid_access_without_refresh_token_is_used_without_writes(self):
        before = self.write_credentials()
        result = billing.kimi_usage()
        self.assertEqual(result.get("windows", {}).get("7d", {}).get("pct"), 45)
        self.http.assert_called_once_with("https://api.kimi.com/coding/v1/usages",
                                          {"Authorization": "Bearer fake-access", "Accept": "application/json"})
        self.assertEqual((self.path.read_bytes(), self.path.stat().st_mtime_ns), before)

    def test_invalid_or_expired_credentials_never_request_or_write(self):
        cases = [(None, "no_credentials"), (b"", "parse"), (b"{broken", "parse"),
                 (b"\xff", "parse"), (b"[]", "parse"), (b"null", "parse"),
                 (b'{"access_token":123}', "parse"),
                 (b'{"access_token":" "}', "no_token"),
                 (b'{"access_token":"","refresh_token":"fake-refresh"}', "no_token"),
                 (b'{"access_token":"fake","expires_at":999999,"refresh_token":"fake-refresh"}', "expired"),
                 (b'{"access_token":"fake","expires_at":"bad"}', "parse"),
                 (b'{"access_token":"fake","expires_at":1e999}', "parse")]
        for raw, expected in cases:
            with self.subTest(raw=raw):
                self.path.unlink(missing_ok=True)
                self.http.reset_mock()
                if raw is not None:
                    self.path.write_bytes(raw)
                result = billing.kimi_usage()
                self.assertEqual(result.get("error"), expected)
                self.http.assert_not_called()
                self.assertEqual(self.path.read_bytes() if self.path.exists() else None, raw)

    def test_custom_root_and_rotated_refresh_token_are_left_untouched(self):
        self.root = self.root / "custom"
        self.path = self.root / "credentials" / "kimi-code.json"
        self.path.parent.mkdir(parents=True)
        before = self.write_credentials(refresh_token="fake-refresh")
        with patch.dict(os.environ, {"KIMI_CODE_HOME": str(self.root)}):
            self.assertIn("windows", billing.kimi_usage())
        self.assertEqual((self.path.read_bytes(), self.path.stat().st_mtime_ns), before)
        self.assertEqual(self.http.call_count, 1)
        self.assertEqual(self.http.call_args.args[0], "https://api.kimi.com/coding/v1/usages")
        self.assertNotIn("method", self.http.call_args.kwargs)

    def test_rejected_access_does_not_refresh_or_force_relogin(self):
        before = self.write_credentials(refresh_token="fake-refresh")
        self.http.return_value = (401, {})
        result = billing.kimi_usage()
        self.assertEqual(result.get("error"), "expired")
        self.assertIn("等待", result.get("detail", ""))
        self.assertEqual(self.http.call_count, 1)
        self.assertEqual((self.path.read_bytes(), self.path.stat().st_mtime_ns), before)

    def quota(self, force=False):
        config = {"entries": [{"id": "kimi", "name": "Kimi", "tool": "kimi", "official": "kimi",
                               "windows": {"7d": {"limit_tokens": 100}}}]}
        with patch.object(quotas, "load_quotas", return_value=config), \
                patch.object(quotas.db, "window_usage", return_value=20), \
                patch.object(quotas.db, "window_unallocated", return_value=0):
            return quotas.compute(None, force=force)["entries"][0]

    def test_credentials_update_recovers_on_next_poll_without_force(self):
        self.write_credentials(access_token="")
        self.assertEqual(self.quota()["source"], "local")
        self.write_credentials()
        entry = self.quota()
        self.assertEqual(entry["source"], "official")
        self.assertFalse(entry["windows"][0]["stale"])
        self.assertEqual(entry["note"], "")
        self.http.assert_called_once()

    def test_credentials_change_does_not_bypass_rate_limit(self):
        self.write_credentials()
        self.http.return_value = (429, {"_retry_after": 300})
        self.quota()
        self.write_credentials(access_token="fake-access-updated")
        self.http.return_value = (200, self.response)
        for force in (False, True):
            with patch.object(billing.time, "time", return_value=self.now + 299):
                self.assertEqual(self.quota(force=force)["source"], "local")
        self.assertEqual(self.http.call_count, 1)
        with patch.object(billing.time, "time", return_value=self.now + 300):
            self.assertEqual(self.quota()["source"], "official")
        self.assertEqual(self.http.call_count, 2)

    def test_expired_access_uses_stale_then_local_after_24_hours(self):
        self.write_credentials()
        self.assertEqual(self.quota()["source"], "official")
        with patch.object(billing.time, "time", return_value=self.now + 901):
            entry = self.quota()
            self.assertTrue(entry["windows"][0]["stale"])
            self.assertIn("等待 Kimi Code", entry["note"])
        with patch.object(billing.time, "time", return_value=self.now + 86401):
            entry = self.quota()
            self.assertEqual(entry["source"], "local")
            self.assertEqual(entry["windows"][0]["pct"], 20)
        self.http.assert_called_once()


class ProviderRetryTest(unittest.TestCase):
    def test_desktop_fallback_preserves_oauth_rate_limit(self):
        with patch.object(billing, "_claude_desktop_usage", return_value={"windows": {"5h": {"pct": 45}}}), \
                patch.object(billing, "_claude_credentials", return_value=[({}, None, "fake")]), \
                patch.object(billing, "_claude_try_source", return_value={"error": "http_429", "_retry_after": 300}):
            result = billing.claude_oauth_usage()
        self.assertEqual(result.get("_retry_after"), 300)

    def test_providers_preserve_retry_after(self):
        limited = {"error": "http_429", "_retry_after": 300}
        with tempfile.TemporaryDirectory(prefix="tt_retry_") as temp:
            credentials = os.path.join(temp, "credentials.json")
            with open(credentials, "w", encoding="utf-8") as f:
                json.dump({"access_token": "fake"}, f)
            for provider in ("claude", "kimi", "codex", "go"):
                with self.subTest(provider=provider), ExitStack() as stack:
                    stack.enter_context(patch.object(billing, "_http_json", return_value=(429, limited)))
                    stack.enter_context(patch.object(billing.os.path, "expanduser", return_value=credentials))
                    stack.enter_context(patch.object(billing, "_kimi_credentials_path", return_value=credentials))
                    stack.enter_context(patch.object(billing, "_go_key", return_value="fake"))
                    stack.enter_context(patch.object(billing, "_codex_credentials",
                                                    return_value=({"access_token": "fake"}, None)))
                    stack.enter_context(patch.object(billing, "_codex_usage_rpc", return_value={"error": "offline"}))
                    stack.enter_context(patch.object(billing, "_claude_desktop_usage", return_value=None))
                    stack.enter_context(patch.object(billing, "_claude_credentials", return_value=[({}, None, "fake")]))
                    stack.enter_context(patch.object(billing, "_claude_try_source", return_value=limited))
                    fetch = {"claude": billing.claude_oauth_usage, "kimi": billing.kimi_usage,
                             "codex": billing.codex_usage, "go": billing.go_usage}[provider]
                    result = fetch()
                    self.assertEqual(result["error"], "http_429")
                    self.assertEqual(result.get("_retry_after"), 300)


class BillingCacheTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="tt_billing_")
        self.addCleanup(temp.cleanup)
        self.path = os.path.join(temp.name, "official_cache.json")
        for p in [patch.object(billing, "_cache", {}),
                  patch.object(billing, "_disk_path", return_value=self.path)]:
            p.start()
            self.addCleanup(p.stop)
        clock = patch.object(billing.time, "time", return_value=1_000_000.0)
        self.clock = clock.start()
        self.addCleanup(clock.stop)

    def test_failure_with_stale_result_obeys_error_backoff(self):
        fetch = Mock(side_effect=[{"windows": {"5h": {"pct": 45}}},
                                  {"error": "offline"}])
        billing._cached("provider", fetch)
        self.clock.return_value += 121
        self.assertEqual(billing._cached("provider", fetch)["_stale_min"], 2)
        self.clock.return_value += 60
        self.assertEqual(billing._cached("provider", fetch)["_stale_min"], 3)
        self.assertEqual(fetch.call_count, 2)

    def test_retry_after_is_not_bypassed_by_forced_refresh(self):
        fetch = Mock(return_value={"error": "http_429", "_retry_after": 300})
        billing._cached("provider", fetch)
        self.clock.return_value += 121
        billing._cached("provider", fetch, force=True)
        self.assertEqual(fetch.call_count, 1)
        self.clock.return_value += 180
        billing._cached("provider", fetch, force=True)
        self.assertEqual(fetch.call_count, 2)

    def test_successful_fallback_still_honors_retry_after(self):
        fetch = Mock(return_value={"windows": {"5h": {"pct": 45}},
                                  "_via": "desktop", "_retry_after": 300})
        billing._cached("provider", fetch)
        self.clock.return_value += 121
        billing._cached("provider", fetch, force=True)
        self.assertEqual(fetch.call_count, 1)

    def test_long_backoff_does_not_keep_success_fresh_or_beyond_24_hours(self):
        fetch = Mock(return_value={"windows": {"5h": {"pct": 45}},
                                  "_via": "desktop", "_retry_after": 90_000})
        billing._cached("provider", fetch)
        self.clock.return_value += 121
        result = billing._cached("provider", fetch, force=True)
        self.assertEqual(result.get("_stale_min"), 2)
        self.clock.return_value += 24 * 3600
        result = billing._cached("provider", fetch, force=True)
        self.assertEqual(result.get("error"), "http_429")
        self.assertNotIn("windows", result)
        self.assertEqual(fetch.call_count, 1)

    def test_memory_and_disk_success_expire_after_24_hours(self):
        fetch = Mock(side_effect=[{"windows": {"5h": {"pct": 45}}},
                                  {"error": "offline"}])
        billing._cached("provider", fetch)
        self.clock.return_value += 24 * 3600 + 1
        result = billing._cached("provider", fetch)
        self.assertEqual(result.get("error"), "offline")
        self.assertNotIn("_stale_min", result)

    def test_success_and_error_cache_last_120_seconds(self):
        for key, data in [("success", {"windows": {}}), ("error", {"error": "offline"})]:
            with self.subTest(key=key):
                fetch = Mock(return_value=data)
                billing._cached(key, fetch)
                self.clock.return_value += 119
                billing._cached(key, fetch)
                self.assertEqual(fetch.call_count, 1)
                self.clock.return_value += 1
                billing._cached(key, fetch)
                self.assertEqual(fetch.call_count, 2)

    def test_simultaneous_force_callers_share_one_request(self):
        start = threading.Barrier(8)
        called = threading.Event()
        release = threading.Event()

        def fetch():
            called.set()
            release.wait(0.2)
            return {"windows": {"5h": {"pct": 45}}}

        fetch_mock = Mock(side_effect=fetch)

        def request():
            start.wait(5)
            return billing._cached("provider", fetch_mock, force=True)

        with ThreadPoolExecutor(max_workers=8) as pool:
            futures = [pool.submit(request) for _ in range(8)]
            self.assertTrue(called.wait(5))
            results = [f.result(timeout=5) for f in futures]
        self.assertEqual(fetch_mock.call_count, 1)
        self.assertTrue(all(r["windows"]["5h"]["pct"] == 45 for r in results))

    def test_disk_writes_preserve_all_providers_across_processes(self):
        ctx = multiprocessing.get_context("spawn")
        start = ctx.Event()
        workers = [ctx.Process(target=_cache_writer, args=(self.path, str(i), start))
                   for i in range(5)]
        for worker in workers:
            worker.start()
        start.set()
        for worker in workers:
            worker.join(10)
            if worker.is_alive():
                worker.terminate()
                worker.join()
            self.assertEqual(worker.exitcode, 0)
        with open(self.path, encoding="utf-8") as f:
            saved = json.load(f)
        self.assertEqual(set(saved), {str(i) for i in range(5)})
        self.assertTrue(all(record[1]["sequence"] == 14 for record in saved.values()))
