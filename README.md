# Reapertoire

Finds, names and renders takes from multitrack rehearsal recordings in REAPER.

Recording a band rehearsal is easy. What is tedious is everything afterwards:
finding where each run-through starts and stops in an hour of continuous audio,
working out which song it was, marking it, and rendering it. Reapertoire does
the finding, reduces the naming to a couple of keystrokes per take, and renders
the results with the metadata a library needs.

It assumes nothing about your lineup. Any instrument may be absent from any
session, including drums, and nothing depends on a particular reference track
existing.

## Requirements

- REAPER 7 (developed against 7.42, macOS)
- [ReaImGui](https://github.com/cfillion/reaimgui) for the panels
- Lua 5.4 to run the tests — `brew install lua@5.4`
- Python 3.12 and `ffmpeg`, for song recognition only

## Install

Symlink the checkout into REAPER's scripts directory:

```sh
ln -s /path/to/reapertoire ~/Library/Application\ Support/REAPER/Scripts/Reapertoire
```

Load `scripts/Reapertoire.lua` from the action list and put it on a toolbar.
That one action is the entry point; it opens a menu of the tools, so nothing
else needs registering.

Then copy the example configuration and edit it:

```sh
cp config/settings.example.json config/settings.json
```

It holds your output path, the detection thresholds, the mapping from REAPER
track names to instrument slugs, and your song list. It is gitignored, so your
repertoire and lineup stay out of the repository.

Song recognition needs its own environment:

```sh
./bin/setup-recognise
```

## Workflow

1. **Tune takes and create regions.** Make a time selection over a rehearsal.
   The panel detects takes, shows them live as you drag the thresholds, and
   writes regions when you are happy.
2. **Name takes.** Arrow between takes — each seeks and plays — type one or two
   letters to filter your songs, press Enter to accept and jump to the next
   unnamed one.
3. **Render named takes.** Produces a master, waveform peaks and per-instrument
   stems for each take, plus a manifest.
4. **Rebuild recognition references.** Feeds the takes you just named back in,
   so the next session arrives with suggestions. See below.

`Analyse (dry run)` reports what detection found without writing anything, and
`Capture tuning fixture` saves a session's level data so thresholds can be tuned
against real audio from the command line rather than by repeated trips through
REAPER.

## How take detection works

Everything is scoped to the time selection.

**Timeline model first.** The union of all media item extents gives alternating
covered and uncovered spans. Uncovered spans are hard cuts where recording was
stopped and restarted — they are not silence, and reading levels across one
yields zeros indistinguishable from a quiet room. A take never spans a hard cut,
regardless of what the audio suggests, because rendering one would bake the gap
into the master.

**Liveness per track.** Each track's noise floor is the 10th percentile of its
*own* frame energies, never a fixed dBFS threshold — an absolute threshold
breaks the moment the lineup or the gain staging changes. A track counts as live
when it exceeds its floor by a margin for a small fraction of its own media, not
of the selection: one short item in an hour-long selection is live for that item.

**Take boundaries.** Each live track is normalised against its own floor, tracks
flagged as microphones are weighted down (talking between takes is loudest
exactly where silence is wanted), and the maximum across tracks per frame gives
one activity curve. One instrument playing is enough to register, so detection
degrades gracefully as the lineup shrinks. Gaps are runs below a threshold
lasting longer than `minGapSec`; takes are the complement, clipped to covered
spans, padded outward and clamped to item edges.

**Per-take instruments.** Which live tracks actually carry signal inside each
take, computed per take rather than per session — players arrive late and sit
tunes out.

Every threshold is configurable and all of them are approximate. The tuning
panel exists because the right values depend on the room, the interface and the
gain staging, and cannot be guessed.

## How song recognition works

Given a take, the recogniser ranks your repertoire by how likely each song is.
It never picks for you: guesses populate the field, and nothing downstream reads
them.

### Why not fingerprinting

Chromaprint and AcoustID identify *the same recording*. A rehearsal take is a
different performance — different tempo, length, lineup, key, arrangement — and
shares almost nothing with another performance at the fingerprint level. This is
**version identification**, a different problem needing different features.

### References come from your own naming

Every take you name and render becomes a labelled reference for next time. The
first session is entirely manual; by the third or fourth most takes should
arrive with a correct top guess. Released studio recordings can serve as weaker
secondary references for songs never yet labelled.

References are stored as extracted features, never audio: a few dozen numbers
per take, so the library stays tiny and survives the source recordings being
deleted.

### Rebuilding the reference library

**Run this after every render.** Recognition can only suggest songs it holds
references for, so the takes you just named do nothing until they are indexed.

From the launcher menu, choose **Rebuild recognition references**. It reports
what it found:

```
Indexed 27 takes across 11 songs:
  A Song (3)
  Another (2)
  ...
```

Or from a terminal:

```sh
.venv/bin/python tools/recognise/recognise.py index \
  --sessions-root ~/Music/RehearsalSessions \
  --out ~/Music/RehearsalSessions/.reapertoire-references.json
```

The library is **derived data**: it is rebuilt from scratch by walking every
`manifest.json` under the sessions root. Deleting it loses nothing, and there
is never a reason not to rebuild it. Doing so is also how the weights get
re-measured -- run `tools/recognise/evaluate.py` afterwards and see whether the
numbers above still hold.

### The pipeline

```
master.mp3 ──ffmpeg──▶ 30 s mono @ 11 kHz ──FFT──▶ spectrogram
   │                   (from the middle)              │
   │                                    ┌─────────────┴─────────────┐
   └──▶ duration                   chroma histogram         spectral flux
                                    (12 pitch classes)      → autocorrelation
                                          │                      → tempo
                                          ▼
                       weighted distance against every reference take
```

Thirty seconds from the **middle** of the take, mono at 11 kHz. Chroma tops out
around 5 kHz and tempo needs less still, so a higher rate buys nothing and costs
decode time. The middle rather than the start because openings are often a
count-in or someone still settling.

### The three features

**Duration** — not scored at all.

Not because it measures poorly, though it does, but because it cannot measure
anything. A take is very often a fragment: one section being worked on, a false
start, the second half after a breakdown. Two takes of the same song routinely
differ by minutes, while two different songs played in full are much the same
length. It is computed and stored for context and left out of the distance.

**Tempo** — weight 0.10. A genuinely independent signal, but a weaker one than
it first appeared, partly because the estimator octave-flips between takes of
the same song.

Computed from *spectral flux*: how much energy appeared since the previous FFT
frame. Rises are onsets; falls are decay and are discarded. Autocorrelating that
envelope finds the period that repeats most strongly, and the peak is
parabolically interpolated — autocorrelation lags are integers, and near 140 BPM
the neighbouring lags are fourteen BPM apart, which is uselessly coarse for a
feature carrying this much weight.

Comparison tries half and double time as well as the reported value. A tracker
reporting 172 where the band feels 86 is a routine octave error, not a different
song.

**Chroma histogram** — weight 0.90, the heaviest. The harmonic identity of the
take, and the feature that actually separates songs.

Every FFT bin between 55 Hz and 4 kHz is converted to a MIDI note number, folded
to one of twelve pitch classes, and its energy accumulated. Below 55 Hz is mostly
rumble; above 4 kHz is mostly cymbals and air. The result is normalised to sum
to one.

Key-independence is achieved at comparison time, by taking the best of all
twelve rotations, rather than by rotating each histogram to its own strongest
pitch class. Rotating by the strongest class is discontinuous: two takes of one
song whose tonic and dominant swap rank -- often a percent or two apart --
would produce completely different vectors.

### Scoring

Each feature contributes a distance in `0..1`, combined by weight. A song scores
as its *closest* reference take — a band plays a tune differently on different
nights, and one good match is evidence. Scores are reported as `1 - distance`,
so higher is better, and the top three are offered.

### Confidence is a margin, not a threshold

A guess is pre-selected only when it beats the runner-up by `minMargin`
(default 0.02). It is deliberately not an absolute score floor.

Measured by leave-one-out over a real library, every score landed between 0.74
and 0.99, so any absolute floor pre-selects wrong answers as readily as right
ones. The wrong answers were characteristically the ones sitting level with
their runner-up — two songs at 0.91 apiece — while correct ones tended to pull
clear. The gap discriminates; the height does not.

Below the margin nothing is pre-selected. A blank field is quicker to deal with
than a plausible wrong answer somebody has to notice and undo.

### How well it works

On a library of twenty-seven takes across eleven songs, leave-one-out over the
twenty-three takes whose song had another reference to match against:

| | |
|---|---|
| top-1 correct | 14/23 (61%) |
| top-3 correct | 23/23 (100%) |
| pre-selected under a 0.02 margin | 3, all correct |

Top-3 is the number that matters for the workflow: the panel offers a short
list, not a verdict.

Feature separation over the same library, which is what the weights are
calibrated against:

| feature | same-song gap | different-song gap | separation |
|---|---|---|---|
| chroma | 0.05 | 0.08 | 0.97 |
| tempo | 4.03 BPM | 10.29 BPM | 0.82 |
| duration | 126.6 s | 100.2 s | **-0.37** (not scored) |

**These numbers reversed the first calibration.** On an early library of four
takes, tempo looked dominant (1.39 against chroma's 0.60) and the weights were
set accordingly. On twenty-seven takes it is the other way round. The first
measurement was small-sample noise, and re-running it is the point of keeping
it scripted.

Duration's negative separation is not noise but a property of the domain, which
is why it is removed rather than down-weighted.

`tools/recognise/evaluate.py` reruns all of this as the library grows. Expect
the weights to move again.

Top-3 is the number that matters for the workflow, since the panel offers a
short list rather than a verdict. This is a small sample and the weights have
not been fitted to it — they are prior judgement, and re-measuring as the
library grows is the point of recording the method here.

### What it deliberately does not do

No waveform peaks: the envelope says nothing about *which* song. No melody
extraction. No beat-synchronous alignment.

Beat-synchronous CQT chroma with subsequence DTW over all twelve rotations is
the standard next step, and is **layer 2** — to be built only if layer 1's top-1
accuracy disappoints against real labelled data. Reaching for it first would be
optimising something not yet measured.

### Implementation

numpy and ffmpeg, no librosa. librosa's beat tracker and CQT are numba-compiled
on first call, which cost nineteen seconds before a single take was analysed —
more than the rest of a session's work put together. Everything layer 1 needs is
a windowed FFT and an autocorrelation.

It runs out of process. A crash in a numeric stack must not take the DAW down
with it, and the two exchange JSON over temporary files.

```sh
# rebuild the library from every named take already rendered
.venv/bin/python tools/recognise/recognise.py index \
  --sessions-root ~/Music/RehearsalSessions \
  --out ~/Music/RehearsalSessions/.reapertoire-references.json

# rank the library against some files
.venv/bin/python tools/recognise/recognise.py match \
  --refs .../.reapertoire-references.json --input takes.json
```

The library is derived data. Delete it and `index` rebuilds it from the
manifests.

## Pushing to a library server

`tools/ingest/upload.py` sends a rendered session to a bandlib-compatible
ingest API. It needs no DAW: the manifest a render produced already holds every
fact the API asks for.

```sh
export REAPERTOIRE_TOKEN=blk_...
.venv/bin/python tools/ingest/upload.py \
  --manifest ~/Music/RehearsalSessions/2026-05-28-practice/manifest.json \
  --api https://example/api/ingest/v1
```

`--dry-run` checks the manifest and the files on disk and contacts nothing.
`--no-publish` leaves takes unpublished for review.

The token is read from the environment and never written anywhere.

**Everything is idempotent.** The session UUID and the region GUIDs are the
client references, so re-posting either returns the existing row rather than
creating a second one. An asset whose hash and size already match is skipped
without re-uploading, which is what lets a run that died on take nine resume
without pushing the first eight again. Presigned URLs live an hour and a slow
uplink outlives that, so an expired URL is refreshed and retried rather than
treated as a failure.

**Two checks run before anything is declared**, because a take declared and
then not uploaded is left stuck mid-ingest on the server:

- Instrument slugs are validated against the server's live vocabulary. Unknown
  slugs are rejected with 422 by design, and the message names both the
  offending slugs and the valid ones.
- Every asset is confirmed present and unchanged in size since the manifest was
  written. A manifest outlives its files when a folder is moved or a render is
  interrupted.

This is the only part of the project whose failure paths are fully testable --
token rejection, expired URLs, resume, structured 409s -- and it is tested
against a mock implementing the contract. `./bin/test` runs that suite too.

## Where things are stored

| What | Where |
|---|---|
| Rendered takes and manifests | `<sessionsRoot>/<date>-<label>/` |
| Reference library | `<sessionsRoot>/.reapertoire-references.json` |
| Which rehearsals a project holds | `.session-metadata.json`, beside the `.rpp` |
| Your configuration | `config/settings.json`, gitignored |

One REAPER project commonly holds many rehearsals appended along the timeline,
so a session is identified by the time range it occupies. Re-running over the
same range converges on the same session rather than creating a second one,
which is what makes re-rendering idempotent.

## Development

```sh
./bin/test
```

The analysis core under `lib/` is pure Lua that never touches REAPER's `reaper`
global — everything it needs is passed in. That is what lets detection be tested
from the command line against captured fixtures, and it is why threshold tuning
is a sub-second loop rather than a click-and-squint cycle inside a DAW.
`adapters/` is the only place REAPER is touched, and `scripts/` are thin actions.

## Licence

MIT — see [LICENSE](LICENSE).

### Third-party

[dkjson](http://dkolf.de/dkjson-lua/) by David Heiko Kolf is vendored at
`lib/util/json.lua`, under its own MIT licence, whose header is kept intact in
that file.
