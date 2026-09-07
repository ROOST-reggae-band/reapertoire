#!/usr/bin/env python3
"""Pushes a rendered session to a bandlib-compatible ingest API.

Reads the manifest a render produced and walks the contract's three phases:
declare the event, declare each take and receive presigned upload URLs, PUT the
bytes, commit. Needs no DAW -- the manifest already holds every fact the API
asks for.

Everything is idempotent by design, because rehearsals get re-rendered, uploads
die halfway and laptops sleep. The session UUID and the region GUIDs are the
client references; re-posting either returns the existing row rather than
creating a second one. An asset whose hash and size already match is skipped
without re-uploading, which is what lets a run that failed on take nine resume
without pushing the first eight again.

Standard library only: urllib, hashlib, json. Nothing here should need
installing to work.

    upload.py --manifest .../manifest.json --api https://example/api/ingest/v1
    upload.py --manifest ... --api ... --dry-run
    upload.py --manifest ... --api ... --no-publish

The token comes from REAPERTOIRE_TOKEN and is never written anywhere.
"""

import argparse
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path

# Presigned PUT URLs live an hour. A slow uplink pushing a whole session will
# outlive that, so a 403 mid-upload is normal operation rather than an error:
# re-declare the take, take the fresh URLs, carry on.
EXPIRY_STATUS = 403
RETRY_STATUSES = (429, 500, 502, 503, 504)
MAX_ATTEMPTS = 4


class IngestError(Exception):
    """An error the operator needs to see, with the API's own words."""


class Client:
    def __init__(self, base_url, token, timeout=120):
        self.base = base_url.rstrip("/")
        self.token = token
        self.timeout = timeout

    # ---------------------------------------------------------------- request

    def _request(self, method, path, body=None, headers=None):
        url = path if path.startswith("http") else f"{self.base}{path}"
        data = None
        merged = {"Authorization": f"Bearer {self.token}"}
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            merged["Content-Type"] = "application/json"
        merged.update(headers or {})

        request = urllib.request.Request(url, data=data, headers=merged, method=method)
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                raw = response.read()
                return response.status, (json.loads(raw) if raw else {})
        except urllib.error.HTTPError as error:
            raw = error.read()
            try:
                payload = json.loads(raw) if raw else {}
            except json.JSONDecodeError:
                payload = {"error": {"code": "unparseable", "message": raw[:200].decode("utf-8", "replace")}}
            return error.status, payload
        except urllib.error.URLError as error:
            raise IngestError(f"cannot reach {url}: {error.reason}") from error

    def _json(self, method, path, body=None):
        """A request whose failure is the operator's problem, not a retry."""
        for attempt in range(1, MAX_ATTEMPTS + 1):
            status, payload = self._request(method, path, body)
            if 200 <= status < 300:
                return payload
            if status in RETRY_STATUSES and attempt < MAX_ATTEMPTS:
                # Retry-After is authoritative when the server sets it; the
                # fallback backs off rather than hammering.
                time.sleep(min(2 ** attempt, 30))
                continue
            raise IngestError(_describe(status, payload))
        raise IngestError(f"{method} {path} still failing after {MAX_ATTEMPTS} attempts")

    # ------------------------------------------------------------- operations

    def instruments(self):
        payload = self._json("GET", "/instruments")
        # The contract does not pin the envelope, so accept either shape.
        if isinstance(payload, list):
            return {i if isinstance(i, str) else i.get("slug") for i in payload}
        for key in ("instruments", "slugs", "data"):
            if key in payload:
                return {i if isinstance(i, str) else i.get("slug") for i in payload[key]}
        return set()

    def declare_event(self, event):
        return self._json("POST", "/events", event)

    def declare_take(self, take):
        return self._json("POST", "/takes", take)

    def refresh_uploads(self, take_id):
        return self._json("GET", f"/takes/{take_id}/uploads")

    def commit(self, take_id, publish=True):
        return self._json("POST", f"/takes/{take_id}/commit", {"publish": publish})

    def put_bytes(self, url, headers, path):
        """Uploads one file. Returns True, or False when the URL has expired."""
        body = Path(path).read_bytes()
        request = urllib.request.Request(url, data=body, headers=headers or {}, method="PUT")
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                return 200 <= response.status < 300
        except urllib.error.HTTPError as error:
            if error.status == EXPIRY_STATUS:
                return False
            raise IngestError(f"upload of {Path(path).name} failed: HTTP {error.status}")
        except urllib.error.URLError as error:
            raise IngestError(f"upload of {Path(path).name} failed: {error.reason}") from error


def _describe(status, payload):
    error = (payload or {}).get("error") or {}
    code = error.get("code", "unknown")
    message = error.get("message", "")
    extra = ""
    # The contract's 409s and 422s carry structured context alongside the
    # error, and it is the part that says what to do about them.
    for key in ("missing", "candidates", "valid", "instruments"):
        if key in (payload or {}):
            extra = f" ({key}: {json.dumps(payload[key])[:200]})"
            break
    return f"HTTP {status} {code}: {message}{extra}"


# ------------------------------------------------------------------- manifest


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def recorded_at(event, take):
    """Wall-clock time of a take, from the session's start plus its offset.

    Take positions are absolute project seconds, which say nothing about when
    something happened; the session's heldAt anchors them.
    """
    held = event.get("heldAt")
    if not held:
        return None
    try:
        started = datetime.fromisoformat(held)
    except ValueError:
        return None
    offset = (take.get("start") or 0) - (event.get("rangeStart") or 0)
    if offset < 0:
        offset = 0
    return (started + timedelta(seconds=offset)).isoformat()


def verify_assets(take, base_dir):
    """Checks each asset is on disk and unchanged since the manifest was written.

    A manifest can outlive its files -- a folder gets moved, a render is
    interrupted, a disk fills. Declaring an asset and then failing to upload it
    leaves a take stuck in `uploading` on the server, so the check happens
    before anything is declared.
    """
    problems = []
    for asset in take.get("assets", []):
        path = Path(asset.get("path", ""))
        if not path.is_absolute():
            path = base_dir / path
        if not path.exists():
            problems.append(f"{asset.get('kind')}: missing {path}")
            continue
        size = path.stat().st_size
        if asset.get("bytes") and size != asset["bytes"]:
            problems.append(
                f"{asset.get('kind')}: {path.name} is {size} bytes, manifest says {asset['bytes']}"
            )
        asset["_resolved"] = str(path)
    return problems


def build_take_payload(event, take):
    assets = []
    for asset in take.get("assets", []):
        entry = {
            "kind": asset["kind"],
            "tier": asset.get("tier", "lossy"),
            "format": asset.get("format"),
            "bytes": asset.get("bytes"),
            "sha256": asset.get("sha256"),
        }
        for optional in ("instrument", "durationMs", "sampleRate", "channels"):
            if asset.get(optional) is not None:
                entry[optional] = asset[optional]
        assets.append(entry)

    return {
        "clientRef": take["clientRef"],
        "eventClientRef": event["clientRef"],
        "song": {
            # The region GUID is the most stable identifier there is: it
            # survives the band renaming the tune.
            "externalRef": take["clientRef"],
            "title": take.get("song"),
            "createIfMissing": True,
        },
        "recordedAt": recorded_at(event, take),
        "durationMs": take.get("durationMs"),
        "label": take.get("label"),
        "instruments": take.get("instruments", []),
        "assets": assets,
    }


# --------------------------------------------------------------------- upload


def upload_session(manifest_path, client, publish=True, dry_run=False, log=print):
    manifest = json.loads(Path(manifest_path).read_text())
    base_dir = Path(manifest_path).parent
    event = manifest["event"]
    takes = manifest.get("takes", [])

    if not event.get("clientRef"):
        raise IngestError("the manifest has no session identifier")

    # Unknown slugs are rejected with 422 by design, so the vocabulary is
    # checked once up front rather than discovered take by take.
    vocabulary = client.instruments() if not dry_run else set()
    if vocabulary:
        used = {i for take in takes for i in take.get("instruments", [])}
        unknown = sorted(used - vocabulary)
        if unknown:
            raise IngestError(
                "these instrument slugs are not in the server's vocabulary: "
                + ", ".join(unknown)
                + "\nEdit the track mapping in config/settings.json to use: "
                + ", ".join(sorted(vocabulary))
            )

    problems = []
    for take in takes:
        problems.extend(verify_assets(take, base_dir))
    if problems:
        raise IngestError("the manifest does not match what is on disk:\n  " + "\n  ".join(problems))

    if dry_run:
        log(f"Would declare event {event['clientRef']} ({event.get('label')})")
        for take in takes:
            names = ", ".join(a["kind"] for a in take.get("assets", []))
            log(f"  {take.get('song')} - {take.get('label')}: {names}")
        return {"takes": len(takes), "uploaded": 0, "skipped": 0, "dryRun": True}

    result = client.declare_event(
        {
            "clientRef": event["clientRef"],
            "kind": event.get("kind", "rehearsal"),
            "heldAt": event.get("heldAt"),
            "venue": event.get("venue"),
            "title": event.get("title"),
            "notes": event.get("notes"),
        }
    )
    log(f"Event {'created' if result.get('created') else 'already known'}: {result.get('eventId')}")

    uploaded = skipped = 0
    for take in takes:
        payload = build_take_payload(event, take)
        declared = client.declare_take(payload)
        take_id = declared["takeId"]

        by_path = {}
        for asset in take.get("assets", []):
            key = (asset["kind"], asset.get("instrument"))
            by_path[key] = asset["_resolved"]

        pending = declared.get("uploads", [])
        for attempt in range(2):
            still_pending = []
            for slot in pending:
                if slot.get("status") == "ready" or not slot.get("url"):
                    skipped += 1
                    continue
                path = by_path.get((slot.get("kind"), slot.get("instrument")))
                if not path:
                    raise IngestError(
                        f"the server asked for an asset the manifest does not have: "
                        f"{slot.get('kind')} {slot.get('instrument') or ''}"
                    )
                if client.put_bytes(slot["url"], slot.get("headers"), path):
                    uploaded += 1
                else:
                    still_pending.append(slot)

            if not still_pending:
                break
            # Expired presigned URLs. Documented as normal operation on a slow
            # uplink, not an error path.
            log(f"  refreshing {len(still_pending)} expired upload URLs")
            pending = client.refresh_uploads(take_id).get("uploads", [])

        committed = client.commit(take_id, publish)
        log(f"  {take.get('song')} - {take.get('label')}: {committed.get('state')}")

    return {"takes": len(takes), "uploaded": uploaded, "skipped": skipped}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--api", required=True, help="base URL, e.g. https://host/api/ingest/v1")
    parser.add_argument("--no-publish", action="store_true",
                        help="leave takes unpublished for review")
    parser.add_argument("--dry-run", action="store_true",
                        help="check the manifest and files, contact nothing")
    args = parser.parse_args()

    token = os.environ.get("REAPERTOIRE_TOKEN", "")
    if not token and not args.dry_run:
        print("REAPERTOIRE_TOKEN is not set.\n"
              "Issue an ingest token in the bandlib admin UI and export it:\n"
              "  export REAPERTOIRE_TOKEN=blk_...", file=sys.stderr)
        return 2

    try:
        summary = upload_session(
            args.manifest, Client(args.api, token),
            publish=not args.no_publish, dry_run=args.dry_run,
        )
    except IngestError as error:
        print(str(error), file=sys.stderr)
        return 1

    print(json.dumps(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
