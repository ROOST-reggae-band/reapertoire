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
is never a reason not to rebuild it. Doing so is also how the accuracy figures
get re-measured -- run `tools/recognise/evaluate.py` afterwards and see whether
the numbers above still hold.

### The pipeline

```
master.mp3 ──ffmpeg──▶ whole take, mono @ 2756 Hz ──FFT──▶ spectrogram
   │                                                          │
   │                                                   log compression
   │                                                          │
   └──▶ duration (stored, not scored)          82 Hz – 1 kHz folded to
                                                  12 pitch classes
                                                          │
                                                per-frame normalise, average
                                                          │
                                                          ▼
                                    distance to the two closest takes
                                        of every song in the library
```

The **whole take**, mono at 2756 Hz. Nothing above 1 kHz is read, so that rate
is Nyquist for the band of interest plus resampler headroom — decoding at 11 kHz
would spend four times the time and memory on content the feature discards.

### The features

**Duration** — not scored at all.

Not because it measures poorly, though it does, but because it cannot measure
anything. A take is very often a fragment: one section being worked on, a false
start, the second half after a breakdown. Two takes of the same song routinely
differ by minutes, while two different songs played in full are much the same
length. It is stored for context and left out of the distance.

**Tempo** — computed historically, no longer used at all. It looked like a
genuinely independent signal and measured as one on a small library, but once
the chroma feature was fixed (below) tempo only made things worse: at weight
0.05 it cost two takes out of twenty-seven, at 0.20 it cost nine. The estimator
octave-flips between takes of the same song — 140 BPM and 70 BPM for the same
tune, in this library — so most of what it contributed was noise. It was removed
rather than down-weighted, which also let the sample rate drop to what chroma
alone needs and is most of why an index now takes seconds.

**Chroma** — the only scored feature, and the one that does all the work. Three
details matter, each of them measured rather than assumed.

*The whole take is analysed, not an excerpt.* This is the single largest factor
in the whole system. On identical data with an identical feature, a 30-second
window from the middle ranks the right song first 74% of the time; the whole
take ranks it first 98%. A rehearsal take is not homogeneous — a short window
can land entirely inside one vamp, and every song has a bar of A minor
somewhere. Analysing eight times as much audio recovers more accuracy than any
amount of cleverness applied to a slice of it.

*Only 82 Hz to 1 kHz is read.* The upper bound is doing real work: above roughly
a kilohertz there is little but upper harmonics, cymbals and air, none of which
says which chord is being played. Dropping the 1–4 kHz band is worth eight
points of top-1 accuracy on its own, and the useful range runs from about 850 Hz
to 1 kHz rather than balancing on one value. The lower bound clears rumble and
the kick fundamental.

*Amplitude is log-compressed.* Without it a single loud snare contributes as
much to the harmonic profile as a bar of sustained chord, and the profile ends
up describing the drummer rather than the song. Compression is worth roughly
fifteen points of top-1 on its own; whether it is `log` or `sqrt` barely
matters, but its absence does.

Each FFT bin in range is converted to a MIDI note number and its energy split
between the two nearest pitch classes in proportion to how close it sits to
each, rather than rounded into one of them — rounding makes the mapping jump
discontinuously as a band tunes a fraction flat. Each frame is normalised before
averaging, so a loud chorus and a quiet verse count equally toward what the song
is.

Key-independence is achieved at comparison time, by taking the best of all
twelve rotations, rather than by rotating each histogram to its own strongest
pitch class. Rotating by the strongest class is discontinuous: two takes of one
song whose tonic and dominant swap rank — often a percent or two apart — would
produce completely different vectors.

Because nothing above 1 kHz is ever read, audio is decoded at 2756 Hz rather
than 11 kHz. That is Nyquist for the band of interest plus headroom for the
resampler's filter, so it is a cheaper route to the same numbers rather than an
approximation — and it makes the whole take affordable to analyse.

### Scoring

A song scores as the mean of its **two closest** reference takes, not its single
closest. The single closest rewards a lucky match against one unrepresentative
take — a false start, a fragment where the band never reached the chorus — and a
song with many references gets more chances to produce one. Requiring two to
agree costs nothing when the match is real: over forty-four held-out takes it
gets 43 right against 42 for the single closest and 38 for the average of all,
and it lifts the narrowest correct call from 2% clear of the runner-up to 11%.

Scores are reported as `1 - distance`, so higher is better, and the top three
are offered.

### Confidence is a relative margin

A guess is pre-selected only when it beats the runner-up by `minMargin`
(default 0.10), measured as a **fraction of the runner-up's distance** rather
than as an absolute gap.

The distinction is not pedantry. Chroma distances are all small and all similar
— scores land between 0.92 and 0.99 — so an absolute floor pre-selects wrong
answers as readily as right ones, and even an absolute *gap* threshold sits in
the third decimal place where it cannot separate anything. The ratio can: over
held-out takes every correct call led its runner-up by at least 11%, with a
median of 59%.

The panel shows this directly, as `Čoudy  62% clear`, because the raw score
carries almost no information and the lead carries nearly all of it.

Below the margin nothing is pre-selected. A blank field is quicker to deal with
than a plausible wrong answer somebody has to notice and undo.

### How well it works

Leave-one-out over a library of forty-four takes across eleven songs — every
take scored against a library with itself removed:

| | |
|---|---|
| top-1 correct | 43/44 (98%) |
| top-3 correct | 44/44 (100%) |
| narrowest correct margin | 11% clear of the runner-up |
| median correct margin | 59% clear |

Top-3 is the number that matters for the workflow: the panel offers a short
list, not a verdict, and on this library the right answer is always in it.

The single remaining error is a mutual confusion between two songs that share a
key and a progression. It is *confidently* wrong — it leads its runner-up by
more than the margin — so the threshold cannot catch it, and pre-selection is
best understood as a convenience that is usually right rather than a verdict.

**These numbers have reversed themselves twice, and that is the point of
recording the method.** An early four-take library made tempo look dominant, and
the weights were set accordingly; twenty-seven takes reversed it. A later
version added sequence matching by dynamic time warping, which measured as an
improvement over averaged chroma on a 30-second excerpt — and became worthless
once the excerpt was replaced by the whole take, at which point the plain
average beat it outright. Both were removed. Re-running the measurement as the
library grows is the method, not a formality.

`tools/recognise/evaluate.py` reruns all of this. Expect it to move again.

### What it deliberately does not do

No waveform peaks: the envelope says nothing about *which* song. No melody
extraction. No beat-synchronous alignment.

Beat-synchronous CQT chroma and cross-recurrence matching (the Qmax family, the
standard approach in the cover-song identification literature) are the obvious
next step and remain unbuilt, deliberately. Subsequence DTW over chroma
sequences *was* tried here and measured worse than the plain average once the
whole take was analysed — 66% against 97%. The lesson generalises: the cheap
structural fix (analyse everything, band-limit it, compress it) outperformed the
sophisticated one, and there is no reason to reach for layer 2 while layer 1
answers correctly forty-three times out of forty-four.

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
