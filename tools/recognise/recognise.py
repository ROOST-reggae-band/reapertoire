#!/usr/bin/env python3
"""Song recognition for rehearsal takes.

Not audio fingerprinting. Chromaprint and AcoustID identify *the same
recording*; a rehearsal take is a different performance of the same song, at a
different tempo, length and lineup. This is version identification, which is a
different problem and needs different features.

Layer 1, deliberately: duration, tempo, and a key-normalised chroma histogram,
scored by weighted distance. For a closed set of twenty-odd songs played at
fairly consistent tempo this may rank the right song first most of the time. It
is measured against real labelled takes before anything heavier is built.

Two commands:

    index  --sessions-root DIR --out refs.json
           Extract features from every named take that has been rendered, and
           store them as the reference library. Features, not audio: the source
           takes may be culled later.

    match  --refs refs.json --input takes.json
           Rank the library against each given file.
"""

import argparse
import json
import sys
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")

# How much each feature counts. Tempo is weighted highest because arrangements
# in this repertoire are fixed, which makes it unusually discriminative; chroma
# carries the harmonic identity; duration is the weakest, since a run-through
# can be cut short or extended.
WEIGHTS = {"tempo": 0.40, "chroma": 0.45, "duration": 0.15}

# Beyond this, a difference tells us nothing more -- two songs 60 s apart in
# length are simply different, and 90 s apart is not "more different".
DURATION_SCALE = 60.0
TEMPO_SCALE = 20.0

SCHEMA = 1


# 11 kHz and one minute. Chroma tops out around 5 kHz and tempo needs less
# still, so higher rates buy nothing and cost a great deal: decoding three
# minutes at 22 kHz took seven seconds a take, which is most of the run.
SAMPLE_RATE = 11025
WINDOW_SECONDS = 60


def _load_audio(path, sr=SAMPLE_RATE, max_seconds=WINDOW_SECONDS, offset=0.0):
    import librosa

    y, actual_sr = librosa.load(
        path, sr=sr, mono=True, duration=max_seconds, offset=offset
    )
    return y, actual_sr


def extract(path):
    """Feature vector for one audio file."""
    import librosa
    import numpy as np

    duration = float(librosa.get_duration(path=str(path)))

    # From the middle of the take: the opening is often a count-in or someone
    # still settling, which says little about which song this is.
    offset = max(0.0, (duration - WINDOW_SECONDS) / 2.0)
    y, sr = _load_audio(path, offset=offset)
    if y.size == 0:
        return None

    tempo, _ = librosa.beat.beat_track(y=y, sr=sr)
    tempo = float(np.atleast_1d(tempo)[0])

    # CQT chroma rather than STFT: it is log-frequency, so it tracks musical
    # pitch classes rather than linear frequency bins.
    chroma = librosa.feature.chroma_cqt(y=y, sr=sr)
    histogram = chroma.mean(axis=1)

    total = float(histogram.sum())
    if total > 0:
        histogram = histogram / total

    # Key-normalised: rotate so the strongest pitch class sits first. The band
    # may play a song in a different key, or a guitar may be tuned down, and
    # neither makes it a different song.
    root = int(np.argmax(histogram))
    histogram = np.roll(histogram, -root)

    return {
        "duration": duration,
        "tempo": tempo,
        "chroma": [round(float(v), 6) for v in histogram],
        "root": root,
    }


def distance(a, b):
    """Weighted distance between two feature vectors. Lower is closer."""
    import numpy as np

    d_dur = min(abs(a["duration"] - b["duration"]) / DURATION_SCALE, 1.0)

    # Compare tempo against its half and double too: a beat tracker reporting
    # 172 where the band feels 86 is a routine octave error, not a different
    # song.
    ta, tb = a["tempo"], b["tempo"]
    candidates = [abs(ta - tb), abs(ta - tb * 2), abs(ta - tb / 2)]
    d_tempo = min(min(candidates) / TEMPO_SCALE, 1.0)

    ca, cb = np.array(a["chroma"]), np.array(b["chroma"])
    d_chroma = float(np.linalg.norm(ca - cb)) / np.sqrt(2.0)
    d_chroma = min(d_chroma, 1.0)

    return (
        WEIGHTS["duration"] * d_dur
        + WEIGHTS["tempo"] * d_tempo
        + WEIGHTS["chroma"] * d_chroma
    )


def cmd_index(args):
    root = Path(args.sessions_root).expanduser()
    library = {"schema": SCHEMA, "songs": {}}

    manifests = sorted(root.glob("*/manifest.json"))
    if not manifests:
        print(f"no manifests under {root}", file=sys.stderr)

    for manifest_path in manifests:
        manifest = json.loads(manifest_path.read_text())
        for take in manifest.get("takes", []):
            song = take.get("song")
            if not song:
                continue
            master = next(
                (a for a in take.get("assets", []) if a.get("kind") == "master"), None
            )
            if not master or not master.get("path"):
                continue
            audio = Path(master["path"])
            if not audio.exists():
                continue

            features = extract(audio)
            if not features:
                continue
            features["takeRef"] = take.get("clientRef")
            features["source"] = str(audio)
            library["songs"].setdefault(song, []).append(features)
            print(f"indexed {song}: {audio.name}", file=sys.stderr)

    Path(args.out).write_text(json.dumps(library, ensure_ascii=False, indent=2))
    counts = {s: len(v) for s, v in library["songs"].items()}
    print(json.dumps({"songs": counts, "total": sum(counts.values())}))


def cmd_match(args):
    refs_path = Path(args.refs)
    library = (
        json.loads(refs_path.read_text())
        if refs_path.exists()
        else {"songs": {}}
    )
    request = json.loads(Path(args.input).read_text())

    results = {}
    for item in request.get("takes", []):
        audio = Path(item["path"])
        if not audio.exists():
            results[item["id"]] = []
            continue

        probe = extract(audio)
        if not probe:
            results[item["id"]] = []
            continue

        scored = []
        for song, references in library.get("songs", {}).items():
            # A song is as close as its closest take: the band plays a tune
            # differently on different nights, and one good match is evidence.
            best = min((distance(probe, r) for r in references), default=None)
            if best is not None:
                scored.append({"song": song, "score": round(1.0 - best, 4)})

        scored.sort(key=lambda s: -s["score"])
        results[item["id"]] = scored[:3]

    print(json.dumps({"results": results}, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p_index = sub.add_parser("index", help="build the reference library")
    p_index.add_argument("--sessions-root", required=True)
    p_index.add_argument("--out", required=True)
    p_index.set_defaults(func=cmd_index)

    p_match = sub.add_parser("match", help="rank the library against takes")
    p_match.add_argument("--refs", required=True)
    p_match.add_argument("--input", required=True)
    p_match.set_defaults(func=cmd_match)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
