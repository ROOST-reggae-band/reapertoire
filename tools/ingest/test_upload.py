#!/usr/bin/env python3
"""Tests for the ingest client, against a mock implementing the contract.

Everything the REAPER-facing code cannot test is testable here: token
rejection, expired presigned URLs, resume after a partial upload, unknown
instrument slugs, a manifest that has outlived its files. Those paths are the
ones that decide whether an upload of several gigabytes over a domestic uplink
survives, and they are exercised nowhere else.

    .venv/bin/python tools/ingest/test_upload.py
"""

import json
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from upload import (  # noqa: E402
    MAX_URL_REFRESHES, Client, IngestError, recorded_at, upload_session,
)

TOKEN = "blk_test_secret"

# The schema wants a real digest: 64 hex characters, not a placeholder.
DIGEST = "a" * 64


class FakeIngest(BaseHTTPRequestHandler):
    """A deliberately literal reading of the contract."""

    # Without this each request negotiates a fresh connection, which urllib
    # then closes -- slow, and noisy in the warnings.
    protocol_version = "HTTP/1.1"

    # Set per test.
    state = {}

    def log_message(self, *args):
        pass

    # ------------------------------------------------------------------ helpers

    def _send(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorised(self):
        if self.headers.get("Authorization") != f"Bearer {TOKEN}":
            self._send(401, {"error": {"code": "unauthorized", "message": "bad token"}})
            return False
        return True

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(length)) if length else {}

    # -------------------------------------------------------------------- verbs

    def do_GET(self):
        if not self._authorised():
            return
        if self.path.endswith("/instruments"):
            self._send(200, {"instruments": [
                {"slug": slug, "label": slug.title()} for slug in self.state["vocabulary"]
            ]})
        elif "/uploads" in self.path:
            self.state["refreshes"] += 1
            self._send(200, {"uploads": self.state["uploads_after_refresh"]})
        else:
            self._send(404, {"error": {"code": "not_found", "message": self.path}})

    def do_POST(self):
        if not self._authorised():
            return
        body = self._body()

        if self.path.endswith("/events"):
            self.state["events"].append(body)
            first = body["clientRef"] not in self.state["known_events"]
            self.state["known_events"].add(body["clientRef"])
            self._send(200, {"eventId": "evt_1", "created": first})

        elif self.path.endswith("/takes"):
            self.state["takes"].append(body)
            if self.state.get("fail_takes_with"):
                status, payload = self.state["fail_takes_with"]
                self._send(status, payload)
                return
            self._send(200, {
                "takeId": "take_1",
                "songId": "song_1",
                "songCreated": True,
                "songMatch": "created-stub",
                "state": "uploading",
                "uploads": self.state["uploads"],
            })

        elif self.path.endswith("/commit"):
            self.state["commits"].append(self.path)
            self._send(200, {"takeId": "take_1", "state": "published", "assets": []})

        else:
            self._send(404, {"error": {"code": "not_found", "message": self.path}})

    def do_PUT(self):
        length = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(length)
        if self.path in self.state["expired_urls"]:
            # One expiry per URL, so a retry after refreshing succeeds --
            # unless the test is exercising a server that never stops.
            if not self.state.get("always_expired"):
                self.state["expired_urls"].discard(self.path)
            self._send(403, {"error": {"code": "expired", "message": "presigned url expired"}})
            return
        self.state["puts"].append((self.path, length))
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()


def fresh_state():
    return {
        "vocabulary": ["bass", "gtr", "organ", "vox-lead"],
        "events": [], "takes": [], "commits": [], "puts": [],
        "known_events": set(), "expired_urls": set(),
        "uploads": [], "uploads_after_refresh": [], "refreshes": 0,
        "fail_takes_with": None, "always_expired": False,
    }


class ServerCase(unittest.TestCase):
    def setUp(self):
        FakeIngest.state = fresh_state()
        self.state = FakeIngest.state
        self.server = HTTPServer(("127.0.0.1", 0), FakeIngest)
        self.port = self.server.server_port
        # serve_forever polls every half second by default and shutdown waits
        # for that poll, which costs half a second per test for nothing.
        threading.Thread(
            target=self.server.serve_forever, kwargs={"poll_interval": 0.01},
            daemon=True).start()
        self.base = f"http://127.0.0.1:{self.port}"
        self.client = Client(self.base, TOKEN)

        self.dir = tempfile.TemporaryDirectory()
        self.root = Path(self.dir.name)

    def tearDown(self):
        self.server.shutdown()
        # Without this the listening socket leaks, which shows up as a
        # ResourceWarning and makes the suite take seconds rather than
        # milliseconds. Test output should be pristine.
        self.server.server_close()
        self.dir.cleanup()

    # --------------------------------------------------------------- fixtures

    def write_manifest(self, takes=None, event=None):
        master = self.root / "master.opus"
        master.write_bytes(b"audio" * 100)
        takes = takes if takes is not None else [{
            "clientRef": "reaper:region-guid:{A}",
            "song": "A Song", "label": "take 1", "takeNo": 1,
            "start": 1100, "durationMs": 254300,
            "instruments": ["bass", "gtr"],
            "assets": [{
                "kind": "master", "tier": "lossy", "format": "opus",
                "path": str(master), "bytes": master.stat().st_size,
                "sha256": DIGEST, "sampleRate": 48000, "channels": 2,
            }],
        }]
        manifest = {
            "schema": 1,
            "event": event or {
                "clientRef": "sess-1", "kind": "rehearsal",
                "heldAt": "2026-09-05T19:30:00+02:00",
                "label": "practice", "rangeStart": 1000,
            },
            "takes": takes,
        }
        path = self.root / "manifest.json"
        path.write_text(json.dumps(manifest))
        return path

    def upload_slot(self, kind="master", instrument=None, status="pending", path="/put/master"):
        return {
            "assetId": "a1", "kind": kind, "instrument": instrument,
            "tier": "lossy", "storageKey": "takes/1/master/lossy.opus",
            "status": status, "method": "PUT",
            "url": f"{self.base}{path}" if status == "pending" else None,
            "headers": {"Content-Type": "audio/ogg"},
        }


class TestHappyPath(ServerCase):
    def test_declares_uploads_and_commits(self):
        self.state["uploads"] = [self.upload_slot()]
        summary = upload_session(self.write_manifest(), self.client, log=lambda *_: None)

        self.assertEqual(summary["uploaded"], 1)
        self.assertEqual(len(self.state["events"]), 1)
        self.assertEqual(len(self.state["takes"]), 1)
        self.assertEqual(len(self.state["puts"]), 1)
        self.assertEqual(len(self.state["commits"]), 1)

    def test_sends_the_region_guid_as_both_refs(self):
        # The contract's most stable identity: it survives the band renaming
        # the tune, which a title does not.
        self.state["uploads"] = [self.upload_slot()]
        upload_session(self.write_manifest(), self.client, log=lambda *_: None)
        take = self.state["takes"][0]
        self.assertEqual(take["clientRef"], "reaper:region-guid:{A}")
        self.assertEqual(take["song"]["externalRef"], "reaper:region-guid:{A}")
        self.assertTrue(take["song"]["createIfMissing"])

    def test_no_publish_is_passed_through(self):
        self.state["uploads"] = [self.upload_slot()]
        upload_session(self.write_manifest(), self.client, publish=False, log=lambda *_: None)
        self.assertEqual(len(self.state["commits"]), 1)


class TestResume(ServerCase):
    def test_an_asset_already_ready_is_not_uploaded_again(self):
        # What lets a run that died on take nine resume without pushing the
        # first eight again.
        self.state["uploads"] = [self.upload_slot(status="ready")]
        summary = upload_session(self.write_manifest(), self.client, log=lambda *_: None)
        self.assertEqual(summary["uploaded"], 0)
        self.assertEqual(summary["skipped"], 1)
        self.assertEqual(self.state["puts"], [])

    def test_an_expired_url_is_refreshed_and_retried(self):
        # Documented as normal operation: presigned URLs live an hour and a
        # slow uplink outlives that.
        self.state["uploads"] = [self.upload_slot(path="/put/expired")]
        self.state["expired_urls"] = {"/put/expired"}
        self.state["uploads_after_refresh"] = [self.upload_slot(path="/put/fresh")]

        summary = upload_session(self.write_manifest(), self.client, log=lambda *_: None)
        self.assertEqual(self.state["refreshes"], 1)
        self.assertEqual(summary["uploaded"], 1)
        self.assertEqual([p for p, _ in self.state["puts"]], ["/put/fresh"])

    def test_re_declaring_an_event_reports_it_as_already_known(self):
        self.state["uploads"] = [self.upload_slot(status="ready")]
        path = self.write_manifest()
        upload_session(path, self.client, log=lambda *_: None)
        lines = []
        upload_session(path, self.client, log=lambda m: lines.append(m))
        self.assertTrue(any("already known" in line for line in lines), lines)


class TestRefusals(ServerCase):
    def test_a_bad_token_is_reported_as_such(self):
        client = Client(self.base, "blk_wrong")
        with self.assertRaises(IngestError) as caught:
            upload_session(self.write_manifest(), client, log=lambda *_: None)
        self.assertIn("401", str(caught.exception))

    def test_unknown_instrument_slugs_stop_the_run_before_anything_is_declared(self):
        # The server rejects unknown slugs with 422 by design. Finding out per
        # take would leave earlier takes half-ingested.
        takes = [{
            "clientRef": "reaper:region-guid:{A}", "song": "A Song", "label": "take 1",
            "start": 1100, "durationMs": 1000,
            "instruments": ["bass", "drums-kick-in"],
            "assets": [],
        }]
        (self.root / "master.opus").write_bytes(b"x")
        with self.assertRaises(IngestError) as caught:
            upload_session(self.write_manifest(takes=takes), self.client, log=lambda *_: None)
        message = str(caught.exception)
        self.assertIn("drums-kick-in", message)
        self.assertIn("bass", message)          # names the valid ones too
        self.assertEqual(self.state["events"], [], "nothing declared")

    def test_a_missing_file_stops_the_run_before_anything_is_declared(self):
        # Declaring an asset then failing to upload leaves the take stuck in
        # `uploading` on the server.
        path = self.write_manifest()
        manifest = json.loads(path.read_text())
        manifest["takes"][0]["assets"][0]["path"] = str(self.root / "gone.opus")
        path.write_text(json.dumps(manifest))

        with self.assertRaises(IngestError) as caught:
            upload_session(path, self.client, log=lambda *_: None)
        self.assertIn("missing", str(caught.exception))
        self.assertEqual(self.state["events"], [])

    def test_a_file_that_changed_size_since_the_manifest_is_caught(self):
        path = self.write_manifest()
        manifest = json.loads(path.read_text())
        manifest["takes"][0]["assets"][0]["bytes"] = 999999
        path.write_text(json.dumps(manifest))

        with self.assertRaises(IngestError) as caught:
            upload_session(path, self.client, log=lambda *_: None)
        self.assertIn("manifest says", str(caught.exception))

    def test_a_manifest_without_a_session_id_is_refused(self):
        path = self.write_manifest(event={"kind": "rehearsal", "heldAt": "2026-01-01T00:00:00Z"})
        with self.assertRaises(IngestError) as caught:
            upload_session(path, self.client, log=lambda *_: None)
        self.assertIn("session identifier", str(caught.exception))

    def test_a_structured_409_is_reported_with_its_context(self):
        # The contract's 409s carry the part that says what to do about them.
        self.state["fail_takes_with"] = (409, {
            "error": {"code": "song_not_found", "message": "no match"},
            "candidates": ["Some Song", "Another"],
        })
        with self.assertRaises(IngestError) as caught:
            upload_session(self.write_manifest(), self.client, log=lambda *_: None)
        message = str(caught.exception)
        self.assertIn("song_not_found", message)
        self.assertIn("Some Song", message)


class TestContractShape(ServerCase):
    """The schemas the server validates against, checked before anything moves.

    Every one of these is a 422 on the server -- but only after the event has
    been declared and takes are going in one at a time, which leaves half a
    session ingested and a message naming one field.
    """

    def refusal(self, *, takes=None, event=None):
        with self.assertRaises(IngestError) as caught:
            upload_session(self.write_manifest(takes=takes, event=event),
                           self.client, log=lambda *_: None)
        self.assertEqual(self.state["events"], [], "nothing declared")
        return str(caught.exception)

    def take(self, **overrides):
        master = self.root / "master.opus"
        master.write_bytes(b"audio" * 100)
        take = {
            "clientRef": "reaper:region-guid:{A}", "song": "A Song",
            "label": "take 1", "start": 1100, "durationMs": 254300,
            "instruments": ["bass"],
            "assets": [{
                "kind": "master", "tier": "lossy", "format": "opus",
                "path": str(master), "bytes": master.stat().st_size,
                "sha256": DIGEST,
            }],
        }
        take.update(overrides)
        return [take]

    def test_a_take_nobody_named_is_refused(self):
        # `song.title` is required. Ingesting an unnamed take would create a
        # stub song called nothing at all.
        self.assertIn("has no song", self.refusal(takes=self.take(song=None)))

    def test_a_session_date_without_an_offset_is_refused(self):
        # "The offset is how it knows what you meant."
        message = self.refusal(event={
            "clientRef": "sess-1", "kind": "rehearsal",
            "heldAt": "2026-09-05T19:30:00", "rangeStart": 1000,
        })
        self.assertIn("UTC offset", message)

    def test_a_session_date_in_zulu_is_accepted(self):
        # Python before 3.11 will not parse a trailing Z, and a manifest
        # carrying one is perfectly ordinary.
        self.state["uploads"] = [self.upload_slot()]
        upload_session(self.write_manifest(event={
            "clientRef": "sess-1", "kind": "rehearsal",
            "heldAt": "2026-09-05T17:30:00Z", "rangeStart": 1000,
        }), self.client, log=lambda *_: None)
        self.assertEqual(self.state["takes"][0]["recordedAt"], "2026-09-05T17:31:40+00:00")

    def test_an_unknown_session_kind_is_refused(self):
        message = self.refusal(event={
            "clientRef": "sess-1", "kind": "jam",
            "heldAt": "2026-09-05T19:30:00+02:00", "rangeStart": 1000,
        })
        self.assertIn("rehearsal", message)

    def test_a_placeholder_hash_is_refused(self):
        take = self.take()
        take[0]["assets"][0]["sha256"] = "abc"
        self.assertIn("64-character hex", self.refusal(takes=take))

    def test_a_stem_without_an_instrument_is_refused(self):
        take = self.take()
        take[0]["assets"][0]["kind"] = "stem"
        self.assertIn("instrument", self.refusal(takes=take))

    def test_peaks_in_anything_but_json_is_refused(self):
        take = self.take()
        take[0]["assets"][0].update(kind="peaks", format="opus")
        self.assertIn("peaks must be json", self.refusal(takes=take))

    def test_the_whole_manifest_is_reported_at_once(self):
        take = self.take(song=None)
        take[0]["assets"][0]["sha256"] = "abc"
        message = self.refusal(takes=take)
        self.assertIn("has no song", message)
        self.assertIn("64-character hex", message)


class TestEventPayload(ServerCase):
    def test_the_session_label_is_sent_as_the_title(self):
        # The manifest calls it `label` and the contract calls it `title`;
        # without the mapping every session arrived nameless.
        self.state["uploads"] = [self.upload_slot()]
        upload_session(self.write_manifest(), self.client, log=lambda *_: None)
        self.assertEqual(self.state["events"][0]["title"], "practice")

    def test_a_blank_take_label_is_sent_as_null_not_empty(self):
        # Nullable, but min-length-1 where present.
        self.state["uploads"] = [self.upload_slot()]
        path = self.write_manifest()
        manifest = json.loads(path.read_text())
        manifest["takes"][0]["label"] = "   "
        path.write_text(json.dumps(manifest))
        upload_session(path, self.client, log=lambda *_: None)
        self.assertIsNone(self.state["takes"][0]["label"])


class TestRetryPolicy(ServerCase):
    def test_a_429_is_not_retried(self):
        # The contract is explicit that the ingest surface returns no 429 in
        # v1, so one is something other than the API answering.
        self.state["fail_takes_with"] = (
            429, {"error": {"code": "slow_down", "message": "too many"}})
        with self.assertRaises(IngestError) as caught:
            upload_session(self.write_manifest(), self.client, log=lambda *_: None)
        self.assertIn("429", str(caught.exception))
        self.assertEqual(len(self.state["takes"]), 1, "declared once, not retried")

    def test_urls_that_keep_expiring_give_up_rather_than_loop(self):
        self.state["uploads"] = [self.upload_slot(path="/put/expired")]
        self.state["uploads_after_refresh"] = [self.upload_slot(path="/put/expired")]
        self.state["expired_urls"] = {"/put/expired"}
        self.state["always_expired"] = True

        with self.assertRaises(IngestError) as caught:
            upload_session(self.write_manifest(), self.client, log=lambda *_: None)
        self.assertIn("refreshes", str(caught.exception))
        self.assertEqual(self.state["refreshes"], MAX_URL_REFRESHES)


class TestErrorContext(ServerCase):
    def test_a_422_names_the_valid_slugs_the_server_listed(self):
        # The server's key is `validSlugs`; looking for anything else threw
        # away the part of the response that says what to do about it.
        self.state["fail_takes_with"] = (422, {
            "error": {"code": "unknown_instrument", "message": "Unknown slug(s): kazoo."},
            "validSlugs": ["bass", "drums"],
        })
        with self.assertRaises(IngestError) as caught:
            upload_session(self.write_manifest(), self.client, log=lambda *_: None)
        message = str(caught.exception)
        self.assertIn("unknown_instrument", message)
        self.assertIn("drums", message)


class TestDryRun(ServerCase):
    def test_contacts_nothing(self):
        summary = upload_session(self.write_manifest(), self.client,
                                 dry_run=True, log=lambda *_: None)
        self.assertTrue(summary["dryRun"])
        self.assertEqual(self.state["events"], [])
        self.assertEqual(self.state["puts"], [])

    def test_still_catches_a_missing_file(self):
        path = self.write_manifest()
        manifest = json.loads(path.read_text())
        manifest["takes"][0]["assets"][0]["path"] = str(self.root / "gone.opus")
        path.write_text(json.dumps(manifest))
        with self.assertRaises(IngestError):
            upload_session(path, self.client, dry_run=True, log=lambda *_: None)


class TestRecordedAt(unittest.TestCase):
    def test_offsets_the_session_start_by_the_takes_position(self):
        event = {"heldAt": "2026-09-05T19:30:00+02:00", "rangeStart": 1000}
        self.assertEqual(
            recorded_at(event, {"start": 1100}), "2026-09-05T19:31:40+02:00")

    def test_a_take_at_the_session_start_is_the_session_time(self):
        event = {"heldAt": "2026-09-05T19:30:00+02:00", "rangeStart": 1000}
        self.assertEqual(
            recorded_at(event, {"start": 1000}), "2026-09-05T19:30:00+02:00")

    def test_a_take_before_the_recorded_start_does_not_go_backwards(self):
        event = {"heldAt": "2026-09-05T19:30:00+02:00", "rangeStart": 1000}
        self.assertEqual(
            recorded_at(event, {"start": 500}), "2026-09-05T19:30:00+02:00")

    def test_an_unparseable_or_absent_date_yields_nothing(self):
        self.assertIsNone(recorded_at({"heldAt": "whenever"}, {"start": 0}))
        self.assertIsNone(recorded_at({}, {"start": 0}))


if __name__ == "__main__":
    unittest.main(verbosity=1)
