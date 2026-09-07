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
import re
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

# Server-side faults only. The contract is explicit that the ingest surface has
# no rate limiting in v1 and never returns 429 -- "don't build retry-on-429
# handling around a code that doesn't exist yet" -- so a 429 from anywhere is
# something other than the ingest API answering, and retrying it is wrong.
RETRY_STATUSES = (500, 502, 503, 504)
MAX_ATTEMPTS = 4

# How many times a take's presigned URLs may be re-issued before the run gives
# up on it. Each round buys another hour, so this covers a genuinely slow push
# without letting a server that keeps returning dead URLs spin forever.
MAX_URL_REFRESHES = 3

# The vocabularies the server validates against. Checked here so a manifest is
# rejected whole, before anything has been declared, rather than one 422 at a
# time after the event exists.
EVENT_KINDS = ("rehearsal", "concert", "session")
AUDIO_FORMATS = ("opus", "mp3", "flac", "wav")
TIERS = ("lossy", "lossless")
HEX_SHA256 = re.compile(r"^[0-9a-f]{64}$", re.IGNORECASE)


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
                # Exponential, so a server that is down rather than briefly
                # busy is not hammered while it comes back.
                time.sleep(min(2 ** attempt, 30))
                continue
            raise IngestError(_describe(status, payload))
        raise IngestError(f"{method} {path} still failing after {MAX_ATTEMPTS} attempts")

    # ------------------------------------------------------------- operations

    def instruments(self):
        """The live slug vocabulary: {"instruments": [{"slug", "label"}]}.

        Entries are read leniently -- a bare slug string is accepted too --
        because only the slug is wanted here and the label is presentation.
        """
        payload = self._json("GET", "/instruments")
        entries = payload if isinstance(payload, list) else payload.get("instruments", [])
        return {i if isinstance(i, str) else i.get("slug") for i in entries}

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
    for key in ("missing", "candidates", "validSlugs"):
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


def held_at(event):
    """The session start as an aware datetime, or None if it cannot be one.

    The contract wants ISO-8601 *with a numeric offset* -- "the offset is how
    it knows what you meant" -- so a naive timestamp is as useless as a
    missing one and is rejected the same way. Python before 3.11 will not
    parse a trailing `Z`, which is a perfectly ordinary thing for a manifest
    to carry, so it is normalised rather than refused.
    """
    held = event.get("heldAt")
    if not held:
        return None
    try:
        started = datetime.fromisoformat(str(held).replace("Z", "+00:00"))
    except ValueError:
        return None
    return started if started.utcoffset() is not None else None


def recorded_at(event, take):
    """Wall-clock time of a take, from the session's start plus its offset.

    Take positions are absolute project seconds, which say nothing about when
    something happened; the session's heldAt anchors them.
    """
    started = held_at(event)
    if started is None:
        return None
    offset = (take.get("start") or 0) - (event.get("rangeStart") or 0)
    if offset < 0:
        offset = 0
    return (started + timedelta(seconds=offset)).isoformat()


def _asset_problems(asset, where):
    """One asset against the server's discriminated union of asset shapes."""
    problems = []
    kind = asset.get("kind")
    tier = asset.get("tier", "lossy")
    fmt = asset.get("format")

    if kind not in ("master", "stem", "peaks"):
        return [f"{where}: kind {kind!r} is none of master, stem, peaks"]
    if tier not in TIERS:
        problems.append(f"{where}: tier {tier!r} is neither lossy nor lossless")

    if kind == "peaks":
        if fmt != "json":
            problems.append(f"{where}: peaks must be json, not {fmt!r}")
    else:
        if fmt not in AUDIO_FORMATS:
            problems.append(
                f"{where}: format {fmt!r} is not one of " + ", ".join(AUDIO_FORMATS))
        if kind == "stem" and not asset.get("instrument"):
            problems.append(f"{where}: a stem must name the instrument it isolates")

    size = asset.get("bytes")
    if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
        problems.append(f"{where}: bytes must be a positive whole number, not {size!r}")

    digest = asset.get("sha256")
    # Optional, but a malformed one is a manifest bug rather than something to
    # quietly drop: the hash is the strongest retry signal the server has, and
    # a wrong one silently costs a re-upload of every take on every resume.
    if digest is not None and not HEX_SHA256.match(str(digest)):
        problems.append(f"{where}: sha256 {digest!r} is not a 64-character hex digest")
    return problems


def contract_problems(event, takes):
    """Everything the ingest schemas require that a manifest can lack.

    The server enforces all of this, but only once the event is declared and
    the takes are going in one at a time, and it names one failing field per
    response. A manifest that cannot be ingested should say so whole, before
    anything on the server has moved -- the same reason `verify_assets` runs
    up front.
    """
    problems = []

    if event.get("kind") not in EVENT_KINDS:
        problems.append(
            f"the session kind is {event.get('kind')!r}, not one of "
            + ", ".join(EVENT_KINDS))
    if held_at(event) is None:
        problems.append(
            f"the session date {event.get('heldAt')!r} is not an ISO-8601 "
            "timestamp with a UTC offset")

    for index, take in enumerate(takes, 1):
        where = f"take {index}"
        if not take.get("clientRef"):
            problems.append(f"{where} has no region GUID to identify it by")
        # The server requires a title: a take nobody named cannot be ingested,
        # and creating a stub song called nothing is worse than stopping.
        if not (take.get("song") or "").strip():
            problems.append(f"{where} has no song")
        if recorded_at(event, take) is None:
            problems.append(f"{where} has no time it was recorded at")
        assets = take.get("assets") or []
        if not assets:
            problems.append(f"{where} rendered no files")
        for asset in assets:
            problems.extend(_asset_problems(asset, f"{where} {asset.get('kind')}"))

    return problems


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
        # Nullable but min-length-1 where present, so a blank label has to go
        # as null rather than as "".
        "label": (take.get("label") or "").strip() or None,
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

    problems = contract_problems(event, takes)
    if problems:
        raise IngestError("the manifest cannot be ingested as it stands:\n  "
                          + "\n  ".join(problems))

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
            # The manifest calls it `label`; the contract calls it `title`.
            # Without the fallback the name of every session was dropped on
            # the floor, since nothing upstream ever writes `title`.
            "title": event.get("title") or event.get("label"),
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
        # URLs live an hour, and a take with a dozen stems on a domestic uplink
        # can outlive more than one of them. The old fixed pair of rounds meant
        # a third expiry silently left files unsent, surfacing only as
        # `assets_incomplete` at commit; the cap is now high enough that a slow
        # push finishes and low enough that a server handing back dead URLs
        # stops rather than spinning.
        for refreshes in range(MAX_URL_REFRESHES + 1):
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
            if refreshes == MAX_URL_REFRESHES:
                raise IngestError(
                    f"{len(still_pending)} uploads for {take.get('song')} - "
                    f"{take.get('label')} still expiring after "
                    f"{MAX_URL_REFRESHES} refreshes; giving up rather than looping"
                )
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
