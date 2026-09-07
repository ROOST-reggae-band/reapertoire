#!/usr/bin/env python3
"""Song recognition for rehearsal takes.

Not audio fingerprinting. Chromaprint and AcoustID identify *the same
recording*; a rehearsal take is a different performance of the same song, at a
different tempo, length and lineup. This is version identification, which is a
different problem and needs different features.

One feature, because one is what measured well: a key-normalised chroma
histogram of the WHOLE take, band-limited to where chords actually live and
amplitude-compressed. Tempo and duration are computed for context and
deliberately not scored -- see the notes on each below. Everything here is
measured against real labelled takes rather than assumed.

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

# Must precede the numpy import: the linear-algebra backend reads these once,
# at load. Takes are already processed one per thread, so letting each tiny
# matmul spawn its own pool of worker threads oversubscribes the machine badly
# -- a dozen pool threads times a dozen BLAS threads, all contending over work
# measured in microseconds. Left unset, indexing a few dozen takes goes from
# seconds to not finishing.
for _threads in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS",
                 "VECLIB_MAXIMUM_THREADS", "NUMEXPR_NUM_THREADS"):
    os.environ.setdefault(_threads, "1")

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

# Chroma is the only feature. Both of the obvious alternatives were tried,
# measured, and removed.
#
# TEMPO hurts. Over twenty-seven held-out takes, chroma alone ranks the right
# song first every time; adding tempo back at any weight makes it worse --
# 0.05 costs two takes, 0.20 costs nine. It is a real signal in the abstract,
# but an autocorrelation tracker octave-flips between takes of the same song
# (140 BPM and 70 BPM for the same tune, in this library), so most of what it
# contributes is noise. Removing it also let the sample rate drop to what
# chroma alone needs, which is most of why an index takes seconds.
#
# DURATION cannot measure anything here, for a reason about the music rather
# than the estimator: a take is very often a fragment -- one section being
# worked on, a false start, the second half after a breakdown. Two takes of the
# same song routinely differ by minutes, while two different songs played in
# full are much the same length. It is still recorded on each reference,
# because it is free and useful when re-tuning, but it is not scored.

# The whole take is analysed, not an excerpt from the middle. This is the single
# largest accuracy factor found: on identical data and an identical feature,
# a 30-second window ranks the right song first 74% of the time and the whole
# take 100%. A rehearsal take is not homogeneous -- a 30-second slice can land
# entirely inside one vamp, and two different songs each have a bar of A minor
# somewhere. The cap only exists so that a pathological forty-minute region
# cannot stall the panel; nothing in the library comes near it.
MAX_ANALYSIS_SECONDS = 600

# Chroma is read between these two frequencies. The upper bound is doing real
# work: above roughly a kilohertz there is little but upper harmonics, cymbals
# and air, and none of it says which chord is being played. Measured, dropping
# 1-4 kHz is worth eight points of top-1 accuracy (92% -> 100%), and the
# plateau runs from about 850 Hz to 1 kHz rather than balancing on one value.
# The lower bound clears rumble and the kick fundamental.
CHROMA_FMIN, CHROMA_FMAX = 82.0, 1000.0

# Nyquist for CHROMA_FMAX, plus headroom for the resampler's filter skirt.
# Nothing above 1000 Hz is read, so decoding at 11 kHz spends four times the
# time and memory on content the feature discards -- and a whole take is a lot
# of samples to throw away. ffmpeg's resampler low-passes on the way down, so
# this is a cheaper route to the same numbers rather than an approximation.
SAMPLE_RATE = 2756

# Chroma wants frequency resolution, because a semitone in the bass is a few
# hertz wide. At this sample rate 1024 bins give 2.7 Hz, which resolves the low
# register that carries chord roots.
FFT_SIZE = 1024
HOP = 256


# Bumped when the stored feature shape changes, so a library written by an
# older version is rebuilt rather than silently compared against.
SCHEMA = 4


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


def _spectrogram(y, n_fft=FFT_SIZE, hop=HOP):
    if y.size < n_fft:
        return None, None
    frames = 1 + (y.size - n_fft) // hop
    window = np.hanning(n_fft).astype(np.float32)

    # One strided view rather than a Python loop over frames: the whole
    # spectrogram is a single FFT call.
    shape = (frames, n_fft)
    strides = (y.strides[0] * hop, y.strides[0])
    blocks = np.lib.stride_tricks.as_strided(y, shape=shape, strides=strides)

    spectrum = np.abs(np.fft.rfft(blocks * window, axis=1)).astype(np.float32)  # noqa: E501
    freqs = np.fft.rfftfreq(n_fft, 1.0 / SAMPLE_RATE)
    return spectrum, freqs


def _chroma_filterbank(freqs):
    """A 12 x bins matrix folding FFT bins onto pitch classes.

    Each bin's energy is split between the two nearest semitones in proportion
    to how close it sits to each, rather than rounded into one of them. A bin
    landing between two notes belongs partly to both, and rounding makes the
    mapping jump discontinuously as a band tunes half a comma flat.
    """
    usable = (freqs >= CHROMA_FMIN) & (freqs <= CHROMA_FMAX)
    midi = 69 + 12 * np.log2(freqs[usable] / 440.0)
    index = np.nonzero(usable)[0]

    bank = np.zeros((12, freqs.size), dtype=np.float32)
    lower = np.floor(midi).astype(int)
    fraction = midi - lower
    np.add.at(bank, (lower % 12, index), (1.0 - fraction).astype(np.float32))
    np.add.at(bank, ((lower + 1) % 12, index), fraction.astype(np.float32))
    return bank


# How much audio one spectrogram covers. numpy's FFT promotes to complex128
# whatever it is given, so a whole 400-second take in one call allocates about
# 140 MB -- times a thread per core, which is enough to put the machine into
# swap and stall an index that should take seconds. Chunking bounds the working
# set to a few megabytes without changing a single output value.
CHUNK_SECONDS = 30


def chroma_histogram(y):
    """Energy per pitch class over the whole take.

    Amplitude is log-compressed first. Without it a single loud snare hit
    contributes as much to the harmonic profile as a bar of sustained chord,
    and the profile ends up describing the drummer. Measured, compression is
    worth about fifteen points of top-1 accuracy on its own.

    Each frame is normalised before averaging, so a loud chorus and a quiet
    verse count equally toward what the song is.
    """
    step = CHUNK_SECONDS * SAMPLE_RATE
    total_chroma = np.zeros(12, dtype=np.float64)
    frames = 0
    bank = None

    # Overlap by one window so no frame straddling a chunk edge is lost.
    for start in range(0, max(1, y.size - FFT_SIZE), step):
        spectrum, freqs = _spectrogram(y[start:start + step + FFT_SIZE])
        if spectrum is None:
            continue
        if bank is None:
            bank = _chroma_filterbank(freqs).T

        chroma = np.log1p(100.0 * spectrum) @ bank

        lengths = np.linalg.norm(chroma, axis=1, keepdims=True)
        lengths[lengths == 0] = 1.0
        chroma /= lengths

        total_chroma += chroma.sum(axis=0)
        frames += chroma.shape[0]

    if frames == 0:
        return None, 0
    histogram = total_chroma / frames
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

    # The whole take, centred if it somehow exceeds the cap.
    seconds = min(file_seconds, MAX_ANALYSIS_SECONDS)
    offset = max(0.0, (file_seconds - seconds) / 2.0)
    y = decode(path, offset, seconds)
    if y.size == 0:
        return None

    histogram, root = chroma_histogram(y)
    if histogram is None:
        return None

    return {
        "duration": duration,
        "analysed": round(seconds, 1),
        "chroma": [round(float(v), 6) for v in histogram],
        "root": root,
    }


def distance(a, b):
    """Distance between two takes' chroma. Lower is closer. Zero to one.

    Chroma alone: see the note above the constants for what tempo and duration
    were measured to contribute, which is nothing and less than nothing.
    """
    # Best of the twelve rotations: the band may play a song in a different
    # key, or a guitar may be tuned down, and neither makes it a different song.
    # Twelve L2 norms over twelve-element vectors costs nothing.
    ca, cb = np.array(a["chroma"]), np.array(b["chroma"])
    best = min(float(np.linalg.norm(np.roll(ca, shift) - cb)) for shift in range(12))
    return min(best / np.sqrt(2.0), 1.0)


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
            if not references:
                continue
            # A song is as close as its TWO closest takes averaged, not its
            # single closest. The single closest rewards a lucky match against
            # one unrepresentative take -- a false start, a fragment where the
            # band never reached the chorus -- and a song with many references
            # gets more chances to produce one. Requiring two to agree costs
            # nothing when the match is real and measurably beats both the
            # single closest and the average of all: over forty-four held-out
            # takes, 97% top-1 against 95% and 86%, and the narrowest correct
            # call goes from 2% clear of the runner-up to 11%.
            ranked = sorted(distance(probe, r) for r in references)
            best = float(np.mean(ranked[:2]))
            scored.append({"song": song, "score": round(1.0 - best, 4)})

        scored.sort(key=lambda s: -s["score"])

        # Confidence is how far the winner is clear of the runner-up, as a
        # FRACTION of the runner-up's distance rather than an absolute gap.
        # Absolute distances between chroma histograms are all small and all
        # similar -- 0.03 against 0.04 -- so a fixed gap threshold cannot tell
        # a decisive win from a coin toss. The ratio can: measured over
        # held-out takes, every correct call led by at least 22%.
        if len(scored) >= 2:
            first, second = 1.0 - scored[0]["score"], 1.0 - scored[1]["score"]
            scored[0]["margin"] = round((second - first) / second, 4) if second > 0 else 0.0
        elif scored:
            scored[0]["margin"] = 1.0

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
