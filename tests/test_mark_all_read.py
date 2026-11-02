import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("news_backend", Path(__file__).resolve().parents[1] / "news_backend.py")
backend = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backend)


class NewsServer:
    """A server fixture that rejects undocumented routes and retains read state."""

    def __init__(self, status=200):
        self.status = status
        self.calls = []
        self.items = [{"id": i, "feedId": feed, "unread": True} for i, feed in [(10, 1), (20, 2), (30, 3)]]
        self.folders = {1: 5, 2: 5, 3: 6}

    def request(self, endpoint, method="GET", json_body=None):
        self.calls.append((endpoint, method, json_body))
        if method == "PUT":
            if self.status != 200:
                return self.status, {"message": "Server rejected the request"}
            if endpoint == "/items/read":
                feeds = set(self.folders)
            elif endpoint == "/feeds/1/read":
                feeds = {1}
            elif endpoint == "/folders/5/read":
                feeds = {1, 2}
            else:
                return 404, {"message": "Unknown route"}
            for item in self.items:
                if item["feedId"] in feeds and item["id"] <= json_body["newestItemId"]:
                    item["unread"] = False
            return 200, {}
        if endpoint == "/folders":
            return 200, {"folders": [{"id": 5, "name": "News"}, {"id": 6, "name": "Other"}]}
        if endpoint == "/feeds":
            return 200, {"feeds": [
                {"id": feed, "folderId": folder, "title": str(feed), "unreadCount": sum(i["unread"] for i in self.items if i["feedId"] == feed)}
                for feed, folder in self.folders.items()
            ]}
        if endpoint.startswith("/items?"):
            return 200, {"items": self.items}
        raise AssertionError(endpoint)


class MarkAllReadTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        paths = patch.multiple(backend, CACHE_DIR=root, DB_PATH=root / "news.db", LEGACY_DB_PATH=root / "absent.db")
        paths.start()
        self.addCleanup(paths.stop)
        self.server = NewsServer()
        self.assertEqual(backend.sync_all(self.server, notify=False), (True, ""))
        self.server.calls.clear()

    def state(self):
        conn = backend.get_db()
        try:
            return ([tuple(r) for r in conn.execute("SELECT id, unread FROM items ORDER BY id")],
                    [tuple(r) for r in conn.execute("SELECT id, unread_count FROM feeds ORDER BY id")])
        finally:
            conn.close()

    def test_all_read_survives_refresh(self):
        self.assertEqual(backend.mark_all_read(self.server), (True, ""))
        self.assertEqual(self.server.calls[0], ("/items/read", "PUT", {"newestItemId": 30}))
        self.assertEqual(backend.sync_all(self.server, notify=False), (True, ""))
        self.assertEqual(self.state(), ([(10, 0), (20, 0), (30, 0)], [(1, 0), (2, 0), (3, 0)]))

    def test_failure_preserves_local_unread_state(self):
        before = self.state()
        for status in [0, 401, 403, 404, 500]:
            with self.subTest(status=status):
                self.server.status = status
                ok, error = backend.mark_all_read(self.server)
                self.assertFalse(ok)
                self.assertIn("Server rejected", error)
                self.assertEqual(self.state(), before)

    def test_scoped_operations_preserve_other_feeds_after_refresh(self):
        for scope, expected in [({"feed_id": 1}, [(10, 0), (20, 1), (30, 1)]),
                                ({"folder_id": 5}, [(10, 0), (20, 0), (30, 1)])]:
            with self.subTest(scope=scope):
                self.server = NewsServer()
                backend.sync_all(self.server, notify=False)
                self.assertEqual(backend.mark_all_read(self.server, **scope), (True, ""))
                backend.sync_all(self.server, notify=False)
                self.assertEqual(self.state()[0], expected)

    def test_signed_out_operation_fails_without_clearing_cache(self):
        before = self.state()
        self.assertFalse(backend.mark_all_read(None)[0])
        self.assertEqual(self.state(), before)

    def test_no_cached_items_does_not_claim_success(self):
        conn = backend.get_db()
        with conn:
            conn.execute("DELETE FROM items")
        conn.close()
        self.assertFalse(backend.mark_all_read(self.server)[0])
        self.assertEqual(self.server.calls, [])


if __name__ == "__main__":
    unittest.main()
