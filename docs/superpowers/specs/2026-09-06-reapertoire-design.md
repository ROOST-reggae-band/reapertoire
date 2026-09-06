# Reapertoire — design

**Date:** 2026-09-06
**Status:** approved design, pre-implementation

Reapertoire turns an unmarked multitrack rehearsal recording in REAPER into
named, rendered takes. It detects where each take starts and stops, asks the
operator which song it was, creates regions, renders them, and writes a
manifest.

The tedium this removes is marking and naming, not rendering. Everything else in
the design serves that.

## Scope

**In scope:** timeline analysis, take detection, a naming panel, region
creation, rendering, a manifest, waveform peaks, and — last — song guessing from
previously named takes.

**Out of scope:** uploads, authentication, and any network call. A downstream
ingest API exists and its contract is frozen; the manifest is shaped to satisfy
it, but nothing here talks to a server.

## Operating assumptions

- Input is a **time selection** in the current project. All work is scoped to it.
- **Attendance varies.** Any instrument may be absent, including drums. Nothing
  may assume a fixed lineup or that a particular reference track exists.
- **A time selection is not necessarily one continuous recording.** The operator
  may have stopped and restarted, leaving hard cuts and multiple items. Single
  long items and many short ones mix within one session.
- **One REAPER project holds many rehearsals**, appended along the timeline.
- Repertoire is a closed set of roughly twenty-odd songs.
- ~2-hour rehearsals, 10–20 takes each. One operator.
- Songs occasionally run back-to-back inside one item with no gap, when
  rehearsing a medley for a gig. Uncommon, but detection cannot find those
  boundaries — a manual split is the only remedy.

## Environment (verified 2026-09-06)

| | |
|---|---|
| OS | macOS 26.6.2, arm64 |
| REAPER | 7.42.0 |
| ReaPack, SWS, js_ReaScriptAPI | installed |
| ReaImGui | **not installed** — required, one-time ReaPack add |
| Python ReaScript | configured against Homebrew 3.11 |

## Decisions

| Decision | Choice | Reasoning |
|---|---|---|
| Language | Lua for everything in milestones 1–5; a Python sidecar only for song guessing | ReaImGui is Lua-first in docs and examples; milestones 1–5 need only percentiles over a few thousand floats; keeping numeric libraries out of REAPER's process means a crash there cannot take down the DAW |
| State | A JSON sidecar beside the `.rpp` is the single source of truth | Enables a genuine dry-run that writes nothing, survives a crash mid-naming, and lets core logic be tested outside REAPER |
| Audio format | Opus | Better quality per byte at rehearsal bitrates; native playback on current phones and browsers |
| Render mechanism | One pass per take with custom time bounds | The region render matrix renders every region in the project — wrong when one `.rpp` holds five rehearsals — and cannot vary its track set per region, which per-take stems require |
| Stem Manager | Not adopted | The native path covers the requirement; the dependency buys nothing |
| Measure snapping | Implemented, shipped off | Project tempo is unlikely to be meaningful on a live-tracked rehearsal, and a wrong snap moves a boundary already verified by ear |

## Architecture

```
reapertoire/
  scripts/                          REAPER actions — thin, no logic
    Reapertoire_Analyze_dryrun.lua  milestone 1: writes nothing
    Reapertoire_Name_takes.lua      the panel; runs detection if needed
    Reapertoire_Render_session.lua  render + manifest
  adapters/
    reaper_api.lua                  the ONLY file touching the `reaper` global
    shell.lua                       sha256 via shasum, isolated for portability
  lib/                              pure Lua, no globals — testable under `lua`
    timeline.lua                    item extents -> covered / uncovered spans
    liveness.lua                    per-track noise floor, live vs absent
    detect.lua                      activity curve -> gaps -> takes
    session.lua                     sidecar schema, atomic I/O, session matching
    manifest.lua                    manifest assembly
    peaks.lua                       1000-int min/max fold
    songs.lua                       known-songs access — one function, swappable
    slugmap.lua                     track name -> instrument slug
    util/json.lua                   vendored dkjson
    util/text.lua                   diacritic folding (Czech)
  config/
    settings.example.json           tracked, generic placeholders
    settings.json                   gitignored, the operator's own
  test/
    fixtures/                       captured frame energies from real sessions
  tools/
    capture_fixture.lua             dumps a real session's energies to fixtures/
```

Everything in `lib/` receives the REAPER adapter as a parameter rather than
reaching for the global. The detector's only input is a frame-energy array,
which is what makes fixtures possible.

`capture_fixture.lua` is what makes milestone 1 tractable: run it once per real
rehearsal, and every subsequent threshold experiment is a sub-second CLI test
rather than a click-and-squint cycle in REAPER.

**Install:** symlink the checkout into REAPER's `Scripts/` directory. Config and
code travel together; `git pull` never touches local settings. Scripts locate
`config/` relative to their own path via `get_action_context()`.

## Configuration

`config/settings.json`, copied from `settings.example.json` on first run — the
console reports the copy, so a placeholder repertoire is never a silent state.

```json
{
  "sessionsRoot": "~/Music/RehearsalSessions",
  "render": { "format": "opus", "bitrateKbps": 128, "stems": true },
  "detection": {
    "frameRateHz": 20, "floorPercentile": 10,
    "liveMarginDb": 12, "liveMinFraction": 0.02,
    "micWeight": 0.35, "gapThresholdDb": 6,
    "minGapSec": 4.0, "minTakeSec": 30.0, "padSec": 0.5,
    "presenceMinFraction": 0.05, "snapToMeasure": false
  },
  "tracks": [
    { "match": "BASS DI", "slug": "bass",     "isMic": false },
    { "match": "VOX",     "slug": "vox-lead", "isMic": true  }
  ],
  "songs": [ { "title": "Example Song", "aliases": ["exmpl"] } ]
}
```

The `tracks` array does double duty deliberately: the same entry supplies the
instrument slug for stem naming and the `isMic` flag that suppresses chatter in
gap detection. Both answer one question — what is this track, musically — so
splitting them would mean maintaining the lineup twice.

`match` is compared case-insensitively against the REAPER track name in three
passes, first hit winning: exact equality, then substring, then fuzzy. A fuzzy
hit is never applied silently — the panel asks for confirmation and writes the
confirmed track name back as an additional entry, so the same drift is never
re-confirmed twice. The layout is mostly stable across sessions but does drift.

Adding a song from the panel rewrites `settings.json` atomically, preserving
top-level key order. The file is therefore not purely hand-owned; this is
accepted because JSON carries no comments to destroy and the songs list is
replaced by a server call in the follow-on project.

## Session state

`.session-metadata.json`, beside the `.rpp`, written atomically (temp + rename)
so naming work is never lost to a crash mid-write.

```json
{
  "schema": 1,
  "sessions": [{
    "id": "5e2c8f1a-...",
    "label": "zkusebna",
    "kind": "rehearsal",
    "heldAt": "2026-09-05T19:30:00+02:00",
    "range": { "start": 0.0, "end": 7204.5 },
    "tracks": [{ "guid": "{...}", "name": "BASS DI 2", "slug": "bass",
                 "live": true, "floorDb": -58.2, "isMic": false }],
    "coveredSpans": [{ "start": 0.0, "end": 3610.2 }],
    "takes": [{ "regionGuid": "{...}", "spanIndex": 0,
                "start": 124.5, "end": 378.8,
                "song": "Dub Corner", "takeNo": 2,
                "instruments": ["bass", "drums", "gtr"],
                "assets": [] }],
    "outputDir": "~/Music/RehearsalSessions/2026-09-05-zkusebna"
  }]
}
```

`kind` is one of `rehearsal`, `concert` or `session`, defaulting to `rehearsal`
and editable in the new-session prompt. It matters downstream — concerts are
surfaced differently and are excluded from retention culling — so it is set at
detection time rather than corrected later.

One event equals one rehearsal, not one project. The downstream contract's prose
assumes a project per rehearsal; its schema does not, since the client reference
is only ever an opaque server-unique string. Scoping the identifier per session
keeps the contract satisfied without revision.

**Session matching on each run:**

- Selection overlaps exactly one session's `range` — a re-run. Converge on it;
  widen `range` if the selection is larger. Never fork.
- Selection overlaps nothing — prompt for date, pre-filled from the earliest
  source file's timestamp, and a label. Both editable.
- Selection overlaps two sessions — refuse, naming both. Do not guess.

**Output path** resolves in three layers and nowhere else in the code:

1. `settings.json` → `sessionsRoot`, the global default.
2. `session.outputDir`, resolved once at session creation as
   `sessionsRoot/YYYY-MM-DD-<label>`, then frozen — changing `sessionsRoot`
   later never scatters an existing session across two folders.
3. A panel field with a Browse button, which edits layer 2.

## Analysis pipeline

Strict order. Each stage's output is the next stage's only input.

1. **Collect.** Per track, items intersecting the selection; per take,
   `GetMediaItemTake_Peaks` at `frameRateHz` into an absolute-time-indexed
   energy array. **Positions with no media are `nil`, never `0`.** This single
   invariant is what stops hard cuts from poisoning noise floors, since a gap in
   the timeline reads identically to a quiet room otherwise.
2. **Timeline model.** Union of item extents across all tracks gives alternating
   covered and uncovered spans. Spans separated by under 50 ms merge — that is an
   item-edge artefact, not a stop/start. Detection runs only inside covered
   spans. Item positions are never read from a single track; players punch in and
   arrive late.
3. **Liveness.** Per track, floor is the `floorPercentile` percentile of that
   track's own non-`nil` frames. A track is live when frames exceeding
   `floor + liveMarginDb` cover more than `liveMinFraction` **of that track's own
   media**, not of the selection — one short item in an hour-long selection is
   live for that item.
4. **Activity curve.** Each live track normalised to dB above its own floor,
   mic-flagged tracks scaled by `micWeight`, then the maximum across tracks per
   frame. One instrument playing is enough to register, so the detector degrades
   gracefully as the lineup shrinks.
5. **Gaps.** Activity below `gapThresholdDb` for at least `minGapSec`. Takes are
   the complement, intersected with the covered spans.
6. **Filter and pad.** Drop takes shorter than `minTakeSec`. Pad by `padSec`,
   clamped to the covered span edge. An assertion then verifies every emitted
   take lies strictly inside exactly one covered span — a take crossing a hard
   cut is a bug, not a tuning problem, and rendering one would bake the gap into
   the master.
7. **Per-take instruments.** A live track is present in a take when it exceeds
   its floor margin for more than `presenceMinFraction` of that take. Computed
   per take, never per session — players arrive late and sit tunes out.

**Dry-run report** goes to the REAPER console and to a file beside the sidecar,
so two threshold settings can be diffed rather than compared by screenshot. It
lists every track as live or absent with its measured floor, the covered spans
found, whether detection subdivided each one, and every take with timestamps,
duration and instruments. Warnings cover unmapped live tracks and takes abutting
a span edge.

A session recorded one-take-per-item shows as spans that detection did not
subdivide — visible in the report, and a signal that detection could be skipped.

## Naming panel

ReaImGui. Missing dependency fails with an explicit ReaPack instruction, not a
nil-index traceback.

Each row shows index, start, duration, detected instruments, a song field and
state.

| Key | Action |
|---|---|
| Up / Down | move rows; selection seeks the transport and plays from the take's start |
| type | filter the song list, diacritic-insensitive both ways, over titles and aliases |
| Enter | accept and jump to the next unnamed row |
| Space | play / pause |
| Esc | clear filter |

No match while typing offers to add the typed title, appended through the same
`songs.lua` accessor that a server call will later replace.

**Corrections**, in ascending order of expected use:

- **Trim start or end to the edit cursor** — the false-start case.
- **Split at the edit cursor** — the medley case. Detection cannot find those
  boundaries, so this is the only way they are made.
- **Merge with next** — enabled only when both rows lie in the same covered span
  and are adjacent. Across a hard cut the control renders disabled with a
  tooltip giving the reason, never a silent refusal.

Unnamed rows stay greyed and are skipped by render.

Region creation is idempotent: a row already carrying a `regionGuid` is updated
in place, never duplicated. Regions take a per-session colour so a project
holding five rehearsals stays readable in the Region Manager. Region names are
`{Song Title} - take {n}` and are human-facing only — identity lives in the GUID
and the sidecar.

**Take numbers are recomputed, never incremented.** Renaming one row reassigns
numbering for both the old and new song in chronological order. An incremental
counter goes wrong the first time a name is corrected.

## Render and manifest

One render pass per named take, custom time bounds, master plus that take's live
mapped tracks.

```
~/Music/RehearsalSessions/2026-09-05-zkusebna/
  manifest.json
  01-dub-corner-take-3/
    master.opus
    peaks.json
    stems/bass.opus
    stems/drums.opus
```

- **Stems render only for tracks live in that take.** An absent player must not
  produce a silent file.
- **An unmapped live track** produces a warning in the report; the master still
  renders and no stem is written. A mapped track absent from the session is
  normal and silent.
- **Peaks** fold the frame energies already collected during analysis into 1000
  integers in −128..127, min/max folded across the take. No re-decode.
- **`sha256` and `bytes`** come from `shasum -a 256` through `adapters/shell.lua`
  — one file to change should this ever leave macOS.

The manifest records, per session, the session identifier, date, kind, label and
output directory; per take, the region GUID, song title, take number, start,
duration in milliseconds and instrument list; per asset, path, bytes, sha256,
sample rate and channels.

## Testing

Core logic in `lib/` runs under Homebrew `lua` 5.4, matching REAPER's, against
captured fixtures. No REAPER global needs stubbing because the adapter is passed
in. Fixture names describe the scenario rather than the band:
`fixture-full-band.json`, `fixture-stop-start.json`, `fixture-missing-drums.json`.

Test-driven development applies to every `lib/` module. The adapters and the
panel are exercised manually in REAPER.

## Milestones

1. **Timeline model, liveness, detection, dry-run report. No project writes** —
   no regions, no markers, no sidecar. The report file and captured fixtures are
   the only output. Tuned
   against at least two real sessions with different lineups and at least one
   recorded with stop/start between takes. Ends with a report to argue with, not
   regions to delete.
2. **Region creation** from a hand-edited span list. No UI.
3. **Naming panel**, manual naming only.
4. **Render and manifest.**
5. **Stems, then peaks.**
6. **Song guessing.**

Milestones 1–3 are the point of the project. Render plumbing does not precede
them.

## Song guessing — deferred to milestone 6

Recorded here so the earlier milestones do not foreclose it. Deliberately last:
the panel is what generates the labelled references that guessing depends on, so
there is nothing to match against until milestones 3–4 have been used for several
real sessions.

Audio fingerprinting is **not applicable** — Chromaprint and AcoustID identify
the same recording, whereas a rehearsal take is a different performance at a
different tempo, length and lineup. This is version identification, a different
technique.

References come chiefly from **previously named takes**, stored as extracted
feature vectors rather than audio, since the source takes may be culled.
Released studio recordings are a weaker secondary source, useful only for songs
never yet correctly labelled.

Matching starts cheap. Layer 1 is scalar: duration, tempo estimate, and a
key-normalised 12-bin chroma histogram, scored by weighted distance. For a closed
set of twenty-odd songs played at consistent tempo this may rank correctly most
of the time. Layer 2 — beat-synchronous CQT chroma with subsequence DTW over all
12 rotations — is built only if layer 1's top-1 accuracy proves insufficient
against real labelled data.

The panel presents the top three candidates with visible scores, top one
pre-selected, and **never auto-accepts**. Below a score floor it pre-selects
nothing: a blank field is faster to handle than a plausible wrong answer that has
to be caught. A wrong label is worse than no label, because downstream the take's
external reference is recorded as a song alias, so a mislabelled take
permanently poisons resolution for that region GUID.

Guesses only ever populate the field. Nothing downstream reads them.

Instrument presence is a free but weak prior. It becomes a small term in the
layer 1 score only once there is labelled data to check it against.

Implementation is a Python sidecar exchanging JSON, invoked per session. The
panel renders detected spans to temporary lossy audio, hands over the paths, and
populates guesses **asynchronously**. Naming must be usable immediately;
matching must never block the panel.

## Open items

- Whether released studio recordings are available locally as references, or
  only via streaming. Affects milestone 6 only.
- Real-world threshold values. Every default in this document is a guess and is
  expected to move during milestone 1.
