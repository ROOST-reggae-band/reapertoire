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

numpy and ffmpeg only, no librosa. librosa's beat tracker and CQT are compiled
by numba on first call, which cost nineteen seconds before a single take was
analysed -- more than the analysis of a whole session. Everything needed here is
a windowed FFT and an autocorrelation, and ffmpeg decodes a minute of audio in
under a second.

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
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np

# GUI applications on macOS do not inherit a login shell's PATH, so a tool
# launched from inside REAPER sees neither /opt/homebrew/bin nor
# /usr/local/bin. Resolve the binaries once, by absolute path.
def _tool(name):
    from shutil import which

    found = which(name)
    if found:
        return found
    for prefix in ("/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"):
        candidate = os.path.join(prefix, name)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return name  # let the failure name the tool it could not find


FFMPEG = _tool("ffmpeg")
FFPROBE = _tool("ffprobe")

# How much each feature counts. Tempo is weighted highest because arrangements
# in this repertoire are fixed, which makes it unusually discriminative; chroma
# carries the harmonic identity; duration is the weakest, since a run-through
# can be cut short or extended.
# Measured, not guessed -- and re-measured, which reversed the first answer.
#
# On four takes, tempo looked dominant (separation 1.39 against chroma's 0.60).
# On twenty-seven it is the other way round: chroma 0.97, tempo 0.82, and
# duration NEGATIVE at -0.37 -- same-song durations differ more than
# different-song ones, so weighting it actively hurt. The first measurement was
# small-sample noise.
#
# Tempo keeps a small weight rather than none: it is a genuinely independent
# signal, and at zero the top-3 rate falls. The exact split between 0.05 and
# 0.15 is within noise on this sample, so a round number is used rather than
# the grid maximum.
WEIGHTS = {"tempo": 0.10, "chroma": 0.90, "duration": 0.0}

# Beyond these, a difference tells us nothing more -- two songs a minute apart
# in length are simply different, and ninety seconds apart is not "more
# different".
DURATION_SCALE = 60.0

# Same-song tempos now spread about 4 BPM against 10 between songs, partly
# because the estimator octave-flips between takes. A wider scale stops that
# spread dominating a feature that is only a supporting signal.
TEMPO_SCALE = 15.0

# Chroma tops out around 5 kHz and tempo needs less still, so a higher rate buys
# nothing and costs decode time.
SAMPLE_RATE = 11025
# Thirty seconds is ample for a chord distribution and a tempo, and halves the
# decode.
WINDOW_SECONDS = 30

FFT_SIZE = 2048
# A smaller hop is finer in time, which matters: tempo is read from integer
# autocorrelation lags, and at hop 512 the usable lags near 140 BPM are 9 and
# 10 -- a 14 BPM step with nothing between them.
HOP = 256

# Reggae sits comfortably inside this, and a wider range mostly invites the
# tracker to lock onto half or double time.
MIN_BPM, MAX_BPM = 60.0, 180.0

# Bumped when the stored feature shape changes, so a library written by an
# older version is rebuilt rather than silently compared against.
SCHEMA = 2


def probe_duration(path):
    out = subprocess.run(
        [FFPROBE, "-v", "error", "-show_entries", "format=duration",
         "-of", "default=nw=1:nk=1", str(path)],
        capture_output=True, text=True,
    )
    try:
        return float(out.stdout.strip())
    except ValueError:
        return 0.0


def decode(path, offset, seconds, sr=SAMPLE_RATE):
    """Mono float32 samples via ffmpeg. Seeking before -i is the fast path."""
    out = subprocess.run(
        [FFMPEG, "-nostdin", "-v", "error",
         "-ss", f"{offset:.3f}", "-t", f"{seconds:.3f}", "-i", str(path),
         "-ac", "1", "-ar", str(sr), "-f", "f32le", "-"],
        capture_output=True,
    )
    return np.frombuffer(out.stdout, dtype=np.float32)


def _spectrogram(y):
    if y.size < FFT_SIZE:
        return None, None
    frames = 1 + (y.size - FFT_SIZE) // HOP
    window = np.hanning(FFT_SIZE).astype(np.float32)

    # One strided view rather than a Python loop over frames: the whole
    # spectrogram is a single FFT call.
    shape = (frames, FFT_SIZE)
    strides = (y.strides[0] * HOP, y.strides[0])
    blocks = np.lib.stride_tricks.as_strided(y, shape=shape, strides=strides)

    spectrum = np.abs(np.fft.rfft(blocks * window, axis=1))
    freqs = np.fft.rfftfreq(FFT_SIZE, 1.0 / SAMPLE_RATE)
    return spectrum, freqs


def chroma_histogram(spectrum, freqs):
    """Energy per pitch class, key-normalised."""
    # Below 55 Hz is mostly rumble; above 4 kHz is mostly cymbals and air, and
    # neither says much about which chord is being played.
    usable = (freqs >= 55.0) & (freqs <= 4000.0)
    freqs = freqs[usable]
    spectrum = spectrum[:, usable]

    # MIDI note number, then pitch class. A4 = 440 Hz = note 69.
    midi = 69 + 12 * np.log2(freqs / 440.0)
    pitch_class = np.rint(midi).astype(int) % 12

    energy = spectrum.sum(axis=0)
    histogram = np.zeros(12, dtype=np.float64)
    np.add.at(histogram, pitch_class, energy)

    total = histogram.sum()
    if total > 0:
        histogram /= total

    # Stored unrotated. Key-independence happens at comparison time by taking
    # the best of all twelve rotations, not by committing to one here: rotating
    # by argmax is discontinuous, so two takes of the same song whose tonic and
    # dominant swap rank -- often a percent or two apart -- would produce
    # completely different vectors.
    root = int(np.argmax(histogram))
    return histogram, root


def estimate_tempo(spectrum):
    """BPM from the autocorrelation of a spectral-flux onset envelope."""
    if spectrum is None or spectrum.shape[0] < 8:
        return 0.0

    # Spectral flux: how much energy appeared since the previous frame. Rises
    # are onsets; falls are decay and are discarded.
    flux = np.diff(spectrum, axis=0)
    flux = np.maximum(flux, 0).sum(axis=1)
    flux -= flux.mean()
    if not np.any(flux):
        return 0.0

    correlation = np.correlate(flux, flux, mode="full")[len(flux) - 1:]

    frames_per_second = SAMPLE_RATE / HOP
    min_lag = max(1, int(frames_per_second * 60.0 / MAX_BPM))
    max_lag = min(len(correlation) - 1, int(frames_per_second * 60.0 / MIN_BPM))
    if max_lag <= min_lag:
        return 0.0

    peak = min_lag + int(np.argmax(correlation[min_lag:max_lag + 1]))

    # Parabolic interpolation around the peak. Lags are integers, so without
    # this the reported tempo can only take the handful of values those lags
    # happen to land on.
    lag = float(peak)
    if 0 < peak < len(correlation) - 1:
        before, at, after = correlation[peak - 1], correlation[peak], correlation[peak + 1]
        denominator = before - 2 * at + after
        if denominator != 0:
            shift = 0.5 * (before - after) / denominator
            if -1.0 < shift < 1.0:
                lag = peak + shift

    if lag <= 0:
        return 0.0
    return float(60.0 * frames_per_second / lag)


def extract(path, duration=None, file_seconds=None):
    """Feature vector for one audio file.

    Two different facts, deliberately separate:

    `duration` is how long the TAKE is, and is what the duration feature
    compares. `file_seconds` is how long this FILE is, and only decides where
    to read from. They differ when the file is a short excerpt cut from the
    middle of a take, which is what the naming panel supplies -- and getting
    them confused makes every probe's duration feature maximally wrong.

    Both are passed in wherever the caller knows them: the manifest records the
    take's duration and the panel knows its own region bounds, so asking
    ffprobe costs a subprocess for a number already in hand.
    """
    if not file_seconds or file_seconds <= 0:
        file_seconds = probe_duration(path)
    if file_seconds <= 0:
        return None
    if not duration or duration <= 0:
        duration = file_seconds

    # From the middle of whatever this file holds. When it is already an
    # excerpt, that is the middle of the excerpt.
    offset = max(0.0, (file_seconds - WINDOW_SECONDS) / 2.0)
    y = decode(path, offset, min(WINDOW_SECONDS, file_seconds))
    if y.size == 0:
        return None

    spectrum, freqs = _spectrogram(y)
    if spectrum is None:
        return None

    histogram, root = chroma_histogram(spectrum, freqs)

    return {
        "duration": duration,
        "tempo": estimate_tempo(spectrum),
        "chroma": [round(float(v), 6) for v in histogram],
        "root": root,
    }


def distance(a, b):
    """Weighted distance between two feature vectors. Lower is closer."""
    d_dur = min(abs(a["duration"] - b["duration"]) / DURATION_SCALE, 1.0)

    # Compare tempo against its half and double too: reporting 172 where the
    # band feels 86 is a routine octave error, not a different song.
    ta, tb = a["tempo"], b["tempo"]
    if ta <= 0 or tb <= 0:
        d_tempo = 1.0
    else:
        gaps = [abs(ta - tb), abs(ta - tb * 2), abs(ta - tb / 2)]
        d_tempo = min(min(gaps) / TEMPO_SCALE, 1.0)

    # Best of the twelve rotations: the band may play a song in a different
    # key, or a guitar may be tuned down, and neither makes it a different song.
    # Twelve L2 norms over twelve-element vectors costs nothing.
    ca, cb = np.array(a["chroma"]), np.array(b["chroma"])
    best = min(float(np.linalg.norm(np.roll(ca, shift) - cb)) for shift in range(12))
    d_chroma = min(best / np.sqrt(2.0), 1.0)

    return (
        WEIGHTS["duration"] * d_dur
        + WEIGHTS["tempo"] * d_tempo
        + WEIGHTS["chroma"] * d_chroma
    )


def extract_many(jobs):
    """Features for several files at once.

    `jobs` are (path, take_duration_or_None, file_seconds_or_None). Each extraction spends most of its time
    waiting on an ffmpeg subprocess, so threads overlap almost perfectly despite
    the GIL.
    """
    if not jobs:
        return []
    workers = min(len(jobs), (os.cpu_count() or 4))
    if workers <= 1:
        return [extract(*job) for job in jobs]
    with ThreadPoolExecutor(max_workers=workers) as pool:
        return list(pool.map(lambda job: extract(*job), jobs))


def cmd_index(args):
    root = Path(args.sessions_root).expanduser()
    library = {"schema": SCHEMA, "songs": {}}

    manifests = sorted(root.glob("*/manifest.json"))
    if not manifests:
        print(f"no manifests under {root}", file=sys.stderr)

    pending = []
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
            if audio.exists():
                seconds = (take.get("durationMs") or 0) / 1000.0 or None
                # The rendered master IS the take, so its length is the take's.
                pending.append((song, audio, take.get("clientRef"), seconds))

    for (song, audio, ref, _), features in zip(
        pending, extract_many([(a, d, d) for _, a, _, d in pending])
    ):
        if not features:
            continue
        features["takeRef"] = ref
        features["source"] = str(audio)
        library["songs"].setdefault(song, []).append(features)

    Path(args.out).write_text(json.dumps(library, ensure_ascii=False, indent=2))
    counts = {s: len(v) for s, v in library["songs"].items()}
    print(json.dumps({"songs": counts, "total": sum(counts.values())}))


def cmd_match(args):
    refs_path = Path(args.refs)
    library = json.loads(refs_path.read_text()) if refs_path.exists() else {"songs": {}}
    request = json.loads(Path(args.input).read_text())

    items = request.get("takes", [])
    probes = extract_many([
        (Path(i["path"]), i.get("duration"), i.get("fileSeconds")) for i in items
    ])

    results = {}
    for item, probe in zip(items, probes):
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
