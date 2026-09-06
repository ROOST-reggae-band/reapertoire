# Reapertoire Milestone 1 — Analysis and Dry Run — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Given a time selection in a REAPER project, report which tracks are live, where the hard cuts are, and where each take starts and stops — writing nothing to the project.

**Architecture:** All analysis lives in pure Lua modules under `lib/` that receive plain arrays and option tables, never the `reaper` global. A single adapter under `adapters/` converts REAPER's world into those arrays. This is what makes the detector testable against captured fixtures on the command line, which is the only practical way to tune its thresholds.

**Tech Stack:** Lua 5.4 (matching REAPER 7.42), ReaScript API, dkjson for config parsing. No other runtime dependencies. Tests run under a hand-rolled runner — no luarocks.

**Spec:** `docs/superpowers/specs/2026-09-06-reapertoire-design.md`

## Global Constraints

- **Target Lua 5.4.** REAPER 7.42 embeds it. Homebrew's default `lua` is 5.5.1 — do not test against it. Install `lua@5.4` and run tests through `bin/test`.
- **`stop`, never `end`.** `end` is a Lua keyword, so every time-range table uses `{ start = number, stop = number }`. JSON serialisation of `end` is deferred to milestone 4.
- **Absence is `false`, never `nil` or `0`.** In a dense frame array, a position where the track has no media is `false`. `nil` creates holes that break `#` and `ipairs`; `0` is indistinguishable from a quiet room and would poison every noise floor. This is the load-bearing invariant of the whole milestone.
- **Nothing in `lib/` may reference the `reaper` global.** If a module needs REAPER, it receives an adapter as a parameter.
- **Milestone 1 makes no project writes** — no regions, no markers, no sidecar. The report file and captured fixtures are the only outputs.
- **No band-identifying strings anywhere** — not in code, config examples, fixture names, test data or commit messages. This project is going to be open-sourced. Example config uses `Example Song`; fixtures are named for their scenario.
- All dB values are negative-going floats; `floor_db` is likewise a dB value, and thresholds are added to it.

---

### Task 1: Verify the peaks API against a real project

The whole collection stage rests on two things the documentation does not state precisely: what time base `starttime` uses, and how the returned buffer is laid out. Confirm both before writing code that assumes them.

**Files:**
- Create: `tools/probe_peaks.lua`
- Create: `docs/notes/reascript-findings.md`

**Interfaces:**
- Consumes: nothing
- Produces: documented facts consumed by Task 8's adapter — the meaning of `starttime`, the buffer block layout, and REAPER's Lua version.

- [ ] **Step 1: Write the probe script**

```lua
-- tools/probe_peaks.lua
-- Run from REAPER's Actions list. Select ONE media item first.
-- Prints what GetMediaItemTake_Peaks actually does, so the adapter can be
-- written against observed behaviour rather than assumed behaviour.

local function log(fmt, ...)
  reaper.ShowConsoleMsg(string.format(fmt .. "\n", ...))
end

reaper.ClearConsole()
log("Lua version: %s", _VERSION)

local item = reaper.GetSelectedMediaItem(0, 0)
if not item then
  log("No item selected. Select one media item and run again.")
  return
end

local take = reaper.GetActiveTake(item)
local src = reaper.GetMediaItemTake_Source(take)
local channels = reaper.GetMediaSourceNumChannels(src)
local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
local offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
local rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")

log("item pos=%.3f len=%.3f startoffs=%.3f playrate=%.3f channels=%d",
    pos, len, offs, rate, channels)

local n = 10
local peakrate = 20
local buf = reaper.new_array(channels * n * 2)
buf.clear()

local retval = reaper.GetMediaItemTake_Peaks(take, peakrate, offs, channels, n, 0, buf)
local returned = retval & 0xfffff
local out_mode = (retval & 0xf00000) >> 20
local has_extra = (retval & 0x1000000) ~= 0

log("retval=%d  samples=%d  out_mode=%d  extra=%s",
    retval, returned, out_mode, tostring(has_extra))

local t = buf.table()
local maxes, mins = {}, {}
for i = 1, returned * channels do
  maxes[#maxes + 1] = string.format("%.4f", t[i])
  mins[#mins + 1] = string.format("%.4f", t[returned * channels + i])
end
log("block 1 (expect maximums): %s", table.concat(maxes, " "))
log("block 2 (expect minimums): %s", table.concat(mins, " "))

log("")
log("Now compare against starttime=0 to learn the time base:")
local buf2 = reaper.new_array(channels * n * 2)
buf2.clear()
local r2 = reaper.GetMediaItemTake_Peaks(take, peakrate, 0, channels, n, 0, buf2)
local t2 = buf2.table()
local first2 = {}
for i = 1, (r2 & 0xfffff) * channels do
  first2[#first2 + 1] = string.format("%.4f", t2[i])
end
log("starttime=0 block 1: %s", table.concat(first2, " "))
log("If these differ from the startoffs run, starttime is SOURCE time.")
log("If identical and startoffs>0, starttime is ITEM-relative.")
```

- [ ] **Step 2: Run it in REAPER**

Copy or symlink the repo into REAPER's `Scripts/` directory, then Actions → Show action list → Load ReaScript → `tools/probe_peaks.lua`. Select a single media item with a non-zero start offset if you have one (drag an item's left edge inward to create one), and run.

- [ ] **Step 3: Record the findings**

Write `docs/notes/reascript-findings.md` with the observed values. It must answer, in plain sentences with the observed numbers quoted:

1. What `_VERSION` REAPER reports. If it is not `Lua 5.4`, stop and report this — the whole plan's version pinning assumes 5.4.
2. Whether block 2 values are consistently lower than block 1 (confirming maximums-then-minimums).
3. Whether `starttime` is source time or item-relative time.
4. Whether `returned` equals the requested `n`, and what happens near the end of a source.

- [ ] **Step 4: Commit**

```bash
git add tools/probe_peaks.lua docs/notes/reascript-findings.md
git commit -m "Add peaks API probe and record observed behaviour"
```

---

### Task 2: Test harness and timeline model

The timeline model turns item extents into covered and uncovered spans. Detection only ever runs inside covered spans, so this is the first thing built and the foundation everything else clips against.

**Files:**
- Create: `bin/test`
- Create: `test/helpers.lua`
- Create: `test/run.lua`
- Create: `lib/timeline.lua`
- Create: `test/timeline_test.lua`
- Create: `.gitignore`

**Interfaces:**
- Consumes: nothing
- Produces: `timeline.covered_spans(items, sel_start, sel_stop, merge_gap) -> array of { start, stop }`, sorted ascending, non-overlapping, clipped to the selection. `helpers.assert_eq`, `helpers.assert_near`, `helpers.assert_spans` for all later test files.

- [ ] **Step 1: Install the matching Lua and create the runner**

```bash
brew install lua@5.4
/opt/homebrew/opt/lua@5.4/bin/lua -v   # expect: Lua 5.4.x
```

```sh
# bin/test
#!/bin/sh
# Runs the pure-Lua test suite on the same Lua version REAPER embeds.
set -e
LUA="${LUA:-/opt/homebrew/opt/lua@5.4/bin/lua}"
if [ ! -x "$LUA" ]; then
  echo "lua@5.4 not found at $LUA — run: brew install lua@5.4" >&2
  echo "(falling back to whatever 'lua' is on PATH; version drift is on you)" >&2
  LUA=lua
fi
exec "$LUA" test/run.lua "$@"
```

```bash
chmod +x bin/test
```

```lua
-- test/helpers.lua
local M = {}

local function fail(msg)
  error(msg, 3)
end

function M.assert_eq(actual, expected, label)
  if actual ~= expected then
    fail(string.format("%s: expected %s, got %s",
      label or "assert_eq", tostring(expected), tostring(actual)))
  end
end

function M.assert_near(actual, expected, tol, label)
  tol = tol or 1e-6
  if type(actual) ~= "number" or math.abs(actual - expected) > tol then
    fail(string.format("%s: expected %s (+/-%s), got %s",
      label or "assert_near", tostring(expected), tostring(tol), tostring(actual)))
  end
end

-- Compares arrays of { start = , stop = } within a tolerance.
function M.assert_spans(actual, expected, label)
  label = label or "assert_spans"
  if #actual ~= #expected then
    local got = {}
    for _, s in ipairs(actual) do
      got[#got + 1] = string.format("[%.3f,%.3f]", s.start, s.stop)
    end
    fail(string.format("%s: expected %d spans, got %d: %s",
      label, #expected, #actual, table.concat(got, " ")))
  end
  for i, want in ipairs(expected) do
    M.assert_near(actual[i].start, want.start, 1e-6,
      string.format("%s[%d].start", label, i))
    M.assert_near(actual[i].stop, want.stop, 1e-6,
      string.format("%s[%d].stop", label, i))
  end
end

return M
```

```lua
-- test/run.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local SUITES = {
  "test.timeline_test",
}

local passed, failed = 0, 0

for _, suite_name in ipairs(SUITES) do
  local suite = require(suite_name)
  local names = {}
  for name in pairs(suite) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local ok, err = pcall(suite[name])
    if ok then
      passed = passed + 1
    else
      failed = failed + 1
      print(string.format("FAIL %s.%s\n     %s", suite_name, name, tostring(err)))
    end
  end
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
```

```
# .gitignore
config/settings.json
test/fixtures/*.local.json
```

- [ ] **Step 2: Write the failing tests**

```lua
-- test/timeline_test.lua
local h = require("test.helpers")
local timeline = require("lib.timeline")

local T = {}

function T.single_item_clipped_to_selection()
  local spans = timeline.covered_spans(
    { { start = 0, stop = 100 } }, 10, 50, 0.05)
  h.assert_spans(spans, { { start = 10, stop = 50 } })
end

function T.overlapping_items_across_tracks_merge_into_one_span()
  -- Everyone recording together: aligned but not identical item edges.
  local spans = timeline.covered_spans({
    { start = 0,    stop = 60 },
    { start = 0.01, stop = 60.02 },
    { start = 0,    stop = 59.98 },
  }, 0, 100, 0.05)
  h.assert_spans(spans, { { start = 0, stop = 60.02 } })
end

function T.hard_cut_produces_two_spans()
  -- Operator stopped and restarted: a real gap in the timeline.
  local spans = timeline.covered_spans({
    { start = 0,  stop = 60 },
    { start = 90, stop = 150 },
  }, 0, 200, 0.05)
  h.assert_spans(spans, { { start = 0, stop = 60 }, { start = 90, stop = 150 } })
end

function T.sub_frame_gaps_merge()
  -- 20 ms between items is an item-edge artefact, not a stop/start.
  local spans = timeline.covered_spans({
    { start = 0,     stop = 60 },
    { start = 60.02, stop = 120 },
  }, 0, 200, 0.05)
  h.assert_spans(spans, { { start = 0, stop = 120 } })
end

function T.late_arrival_extends_coverage_without_shortcutting()
  -- Trumpet arrives late: its item starts after everyone else's ends.
  local spans = timeline.covered_spans({
    { start = 0,   stop = 60 },
    { start = 200, stop = 260 },
  }, 0, 300, 0.05)
  h.assert_spans(spans, { { start = 0, stop = 60 }, { start = 200, stop = 260 } })
end

function T.items_entirely_outside_selection_are_dropped()
  local spans = timeline.covered_spans({
    { start = 0,   stop = 10 },
    { start = 500, stop = 600 },
  }, 100, 400, 0.05)
  h.assert_spans(spans, {})
end

function T.zero_length_intersection_is_dropped()
  local spans = timeline.covered_spans(
    { { start = 0, stop = 100 } }, 100, 200, 0.05)
  h.assert_spans(spans, {})
end

function T.unsorted_input_is_handled()
  local spans = timeline.covered_spans({
    { start = 90, stop = 150 },
    { start = 0,  stop = 60 },
  }, 0, 200, 0.05)
  h.assert_spans(spans, { { start = 0, stop = 60 }, { start = 90, stop = 150 } })
end

function T.fully_contained_item_does_not_shorten_its_span()
  local spans = timeline.covered_spans({
    { start = 0,  stop = 100 },
    { start = 20, stop = 30 },
  }, 0, 200, 0.05)
  h.assert_spans(spans, { { start = 0, stop = 100 } })
end

return T
```

- [ ] **Step 3: Run the tests and confirm they fail**

Run: `./bin/test`
Expected: FAIL, `module 'lib.timeline' not found`.

- [ ] **Step 4: Implement the timeline model**

```lua
-- lib/timeline.lua
-- Builds the covered/uncovered structure of the timeline from item extents.
--
-- Detection only ever runs inside a covered span. An uncovered span is a hard
-- cut where the operator stopped and restarted; it is NOT silence, and reading
-- peaks across it would yield zeros indistinguishable from a quiet room.

local M = {}

-- items      array of { start = number, stop = number }, any order, may overlap
-- sel_start  selection start, seconds
-- sel_stop   selection stop, seconds
-- merge_gap  spans separated by at most this many seconds are joined; use a
--            small value (0.05) so item-edge artefacts merge but real
--            stop/start cuts do not
--
-- Returns an ascending, non-overlapping array of { start = , stop = }.
function M.covered_spans(items, sel_start, sel_stop, merge_gap)
  local clipped = {}
  for _, item in ipairs(items) do
    local s = math.max(item.start, sel_start)
    local e = math.min(item.stop, sel_stop)
    if e > s then
      clipped[#clipped + 1] = { start = s, stop = e }
    end
  end

  table.sort(clipped, function(a, b)
    if a.start == b.start then return a.stop < b.stop end
    return a.start < b.start
  end)

  local out = {}
  for _, span in ipairs(clipped) do
    local last = out[#out]
    if last and span.start - last.stop <= merge_gap then
      if span.stop > last.stop then last.stop = span.stop end
    else
      out[#out + 1] = { start = span.start, stop = span.stop }
    end
  end

  return out
end

return M
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `./bin/test`
Expected: `9 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add bin/test test/helpers.lua test/run.lua test/timeline_test.lua lib/timeline.lua .gitignore
git commit -m "Add test harness and timeline covered-span model"
```

---

### Task 3: Frame index helpers

Three later modules convert between wall-clock seconds and frame indices. Getting this off-by-one wrong in three places independently is the obvious failure, so it lives in one module with its own tests.

**Files:**
- Create: `lib/util/frames.lua`
- Create: `test/frames_test.lua`
- Modify: `test/run.lua`

**Interfaces:**
- Consumes: nothing
- Produces: `frames.index_of(t, sel_start, rate) -> integer` (1-based), `frames.time_of(i, sel_start, rate) -> number`, `frames.count(sel_start, sel_stop, rate) -> integer`.

- [ ] **Step 1: Write the failing tests**

```lua
-- test/frames_test.lua
local h = require("test.helpers")
local frames = require("lib.util.frames")

local T = {}

function T.first_frame_is_index_one()
  h.assert_eq(frames.index_of(0, 0, 20), 1)
  h.assert_eq(frames.index_of(100, 100, 20), 1)
end

function T.index_advances_with_the_frame_rate()
  h.assert_eq(frames.index_of(0.05, 0, 20), 2)
  h.assert_eq(frames.index_of(1.0, 0, 20), 21)
end

function T.index_is_relative_to_selection_start()
  h.assert_eq(frames.index_of(101.0, 100, 20), 21)
end

function T.time_of_inverts_index_of()
  h.assert_near(frames.time_of(1, 100, 20), 100)
  h.assert_near(frames.time_of(21, 100, 20), 101)
end

function T.count_covers_the_whole_selection()
  h.assert_eq(frames.count(0, 1, 20), 20)
  h.assert_eq(frames.count(0, 1.5, 20), 30)
end

function T.count_rounds_up_a_partial_final_frame()
  h.assert_eq(frames.count(0, 1.01, 20), 21)
end

return T
```

- [ ] **Step 2: Register the suite and run to confirm failure**

In `test/run.lua`, extend `SUITES` to:

```lua
local SUITES = {
  "test.timeline_test",
  "test.frames_test",
}
```

Run: `./bin/test`
Expected: FAIL, `module 'lib.util.frames' not found`.

- [ ] **Step 3: Implement**

```lua
-- lib/util/frames.lua
-- Conversions between wall-clock seconds and 1-based frame indices in a dense
-- analysis array covering a time selection.

local M = {}

-- Frame index containing time t. 1-based, so sel_start itself is frame 1.
function M.index_of(t, sel_start, rate)
  return math.floor((t - sel_start) * rate + 1e-9) + 1
end

-- Start time of frame i.
function M.time_of(i, sel_start, rate)
  return sel_start + (i - 1) / rate
end

-- Number of frames needed to cover [sel_start, sel_stop], rounding up so a
-- partial final frame is still represented.
function M.count(sel_start, sel_stop, rate)
  return math.ceil((sel_stop - sel_start) * rate - 1e-9)
end

return M
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `./bin/test`
Expected: `15 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add lib/util/frames.lua test/frames_test.lua test/run.lua
git commit -m "Add frame index conversion helpers"
```

---

### Task 4: Track liveness

Classify each track as live or absent using its own noise floor, so the result survives a lineup change or a gain-staging change. An absolute dBFS threshold would not.

**Files:**
- Create: `lib/liveness.lua`
- Create: `test/liveness_test.lua`
- Modify: `test/run.lua`

**Interfaces:**
- Consumes: nothing
- Produces: `liveness.percentile(values, p) -> number|nil`; `liveness.classify(frames, opts) -> { live, floor_db, active_fraction, media_frames }` where `frames` is a dense array of dB numbers and `false`, and `opts` carries `floor_percentile`, `live_margin_db`, `live_min_fraction`.

- [ ] **Step 1: Write the failing tests**

```lua
-- test/liveness_test.lua
local h = require("test.helpers")
local liveness = require("lib.liveness")

local T = {}

local OPTS = {
  floor_percentile = 10,
  live_margin_db = 12,
  live_min_fraction = 0.02,
}

-- Builds a dense frame array: `n` frames at `quiet` dB, with `loud_count`
-- frames raised to `loud` dB, optionally surrounded by `false` (no media).
local function make_frames(opts)
  local out = {}
  for _ = 1, (opts.leading_absent or 0) do out[#out + 1] = false end
  for i = 1, opts.n do
    out[#out + 1] = (i <= (opts.loud_count or 0)) and opts.loud or opts.quiet
  end
  for _ = 1, (opts.trailing_absent or 0) do out[#out + 1] = false end
  return out
end

function T.percentile_uses_nearest_rank()
  local v = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }
  h.assert_eq(liveness.percentile(v, 10), 1)
  h.assert_eq(liveness.percentile(v, 50), 5)
  h.assert_eq(liveness.percentile(v, 100), 10)
end

function T.percentile_of_empty_is_nil()
  h.assert_eq(liveness.percentile({}, 10), nil)
end

function T.percentile_does_not_mutate_its_input()
  local v = { 3, 1, 2 }
  liveness.percentile(v, 50)
  h.assert_eq(v[1], 3, "input reordered")
end

function T.silent_track_is_not_live()
  local r = liveness.classify(
    make_frames({ n = 1000, quiet = -60 }), OPTS)
  h.assert_eq(r.live, false)
end

function T.playing_track_is_live()
  local r = liveness.classify(
    make_frames({ n = 1000, quiet = -60, loud = -12, loud_count = 400 }), OPTS)
  h.assert_eq(r.live, true)
  h.assert_near(r.active_fraction, 0.4, 1e-9)
end

function T.room_bleed_alone_is_not_live()
  -- An absent player's mic picks up the room: above the floor, but only just,
  -- and never by the 12 dB margin.
  local r = liveness.classify(
    make_frames({ n = 1000, quiet = -60, loud = -55, loud_count = 900 }), OPTS)
  h.assert_eq(r.live, false)
end

function T.track_with_no_media_at_all_is_not_live()
  local r = liveness.classify({ false, false, false }, OPTS)
  h.assert_eq(r.live, false)
  h.assert_eq(r.media_frames, 0)
  h.assert_eq(r.floor_db, nil)
end

function T.liveness_is_judged_over_own_media_not_selection_length()
  -- One 30-second item inside an hour-long selection, played through with the
  -- normal rests any real part contains. Judged over the selection it would
  -- look 99% silent; judged over its own media it is unambiguously live.
  local r = liveness.classify(make_frames({
    leading_absent = 60000,
    n = 600, quiet = -60, loud = -10, loud_count = 500,
    trailing_absent = 11400,
  }), OPTS)
  h.assert_eq(r.live, true)
  h.assert_eq(r.media_frames, 600)
  h.assert_near(r.active_fraction, 500 / 600, 1e-9)
end

function T.a_track_that_never_rests_has_no_measurable_floor()
  -- Pinned deliberately: a self-referential floor needs the track to be quiet
  -- sometimes. A part with literally no rests has a floor equal to its own
  -- signal level and classifies as absent. Real parts always contain rests, so
  -- this does not bite in practice — but it is why the dry-run report prints
  -- the measured floor per track, where a floor of -10 dB is visibly wrong.
  local frames = {}
  for i = 1, 1000 do frames[i] = -10 end
  local r = liveness.classify(frames, OPTS)
  h.assert_eq(r.live, false)
  h.assert_near(r.floor_db, -10, 1e-9)
end

function T.absent_frames_never_reach_the_floor_calculation()
  -- If `false` were treated as 0 dB, the floor would be dragged far upward and
  -- the real signal would fall below the margin.
  local r = liveness.classify(make_frames({
    leading_absent = 9000,
    n = 1000, quiet = -60, loud = -12, loud_count = 400,
  }), OPTS)
  h.assert_near(r.floor_db, -60, 1e-9)
  h.assert_eq(r.live, true)
end

return T
```

- [ ] **Step 2: Register the suite and run to confirm failure**

Extend `SUITES` in `test/run.lua` with `"test.liveness_test"`.

Run: `./bin/test`
Expected: FAIL, `module 'lib.liveness' not found`.

- [ ] **Step 3: Implement**

```lua
-- lib/liveness.lua
-- Decides which tracks carry a player this session.
--
-- The floor is computed per track from the track's own frames, not from a
-- fixed dBFS threshold: absolute thresholds break the moment the lineup or the
-- gain staging changes. Liveness is judged over the track's own media, not the
-- selection's wall-clock length, so one short item in a long selection counts
-- as live for that item rather than reading as 98% silence.

local M = {}

-- Nearest-rank percentile. Returns nil for an empty set. Does not mutate.
function M.percentile(values, p)
  if #values == 0 then return nil end
  local sorted = table.move(values, 1, #values, 1, {})
  table.sort(sorted)
  local rank = math.ceil(p / 100 * #sorted)
  if rank < 1 then rank = 1 end
  if rank > #sorted then rank = #sorted end
  return sorted[rank]
end

-- frames  dense array; each element is a dB number, or `false` where the track
--         has no media at that position. Never nil, never 0.
-- opts    { floor_percentile, live_margin_db, live_min_fraction }
function M.classify(frames, opts)
  local present = {}
  for _, v in ipairs(frames) do
    if v ~= false then present[#present + 1] = v end
  end

  if #present == 0 then
    return { live = false, floor_db = nil, active_fraction = 0, media_frames = 0 }
  end

  local floor_db = M.percentile(present, opts.floor_percentile)
  local threshold = floor_db + opts.live_margin_db

  local active = 0
  for _, v in ipairs(present) do
    if v > threshold then active = active + 1 end
  end

  local fraction = active / #present
  return {
    live = fraction > opts.live_min_fraction,
    floor_db = floor_db,
    active_fraction = fraction,
    media_frames = #present,
  }
end

return M
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `./bin/test`
Expected: `25 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add lib/liveness.lua test/liveness_test.lua test/run.lua
git commit -m "Add per-track liveness classification"
```

---

### Task 5: Take detection

Combine live tracks into one activity curve, find the gaps, and turn the complement into takes clipped to covered spans. This is the module whose thresholds will actually need tuning, which is why it is pure and fixture-driven.

**Files:**
- Create: `lib/detect.lua`
- Create: `test/detect_test.lua`
- Modify: `test/run.lua`

**Interfaces:**
- Consumes: `lib.util.frames`
- Produces:
  - `detect.activity(tracks, opts, n_frames) -> array of number|false` — dB above own floor, mic-weighted, maxed across live tracks.
  - `detect.takes(activity, covered_spans, sel_start, rate, opts) -> array of { start, stop, span_index }`.
  - `tracks` elements are `{ frames = , floor_db = , live = , is_mic = }`.
  - `opts` carries `mic_weight`, `gap_threshold_db`, `min_gap_sec`, `min_take_sec`, `pad_sec`.

- [ ] **Step 1: Write the failing tests**

```lua
-- test/detect_test.lua
local h = require("test.helpers")
local detect = require("lib.detect")

local T = {}

local RATE = 20

local OPTS = {
  mic_weight = 0.35,
  gap_threshold_db = 6,
  min_gap_sec = 4.0,
  min_take_sec = 30.0,
  pad_sec = 0.5,
}

-- Builds a dense frame array of `total` frames at `quiet` dB, with the given
-- second-ranges raised to `loud` dB.
local function track_frames(total, quiet, loud, loud_ranges)
  local out = {}
  for i = 1, total do out[i] = quiet end
  for _, r in ipairs(loud_ranges or {}) do
    for i = math.floor(r[1] * RATE) + 1, math.floor(r[2] * RATE) do
      out[i] = loud
    end
  end
  return out
end

function T.activity_is_db_above_the_tracks_own_floor()
  local tracks = {
    { frames = { -30, -60 }, floor_db = -60, live = true, is_mic = false },
  }
  local a = detect.activity(tracks, OPTS, 2)
  h.assert_near(a[1], 30)
  h.assert_near(a[2], 0)
end

function T.activity_takes_the_max_across_live_tracks()
  -- One instrument playing is enough; the detector must not need the whole band.
  local tracks = {
    { frames = { -58 }, floor_db = -60, live = true, is_mic = false },
    { frames = { -20 }, floor_db = -60, live = true, is_mic = false },
  }
  h.assert_near(detect.activity(tracks, OPTS, 1)[1], 40)
end

function T.absent_tracks_are_ignored_entirely()
  local tracks = {
    { frames = { -10 }, floor_db = -60, live = false, is_mic = false },
    { frames = { -55 }, floor_db = -60, live = true,  is_mic = false },
  }
  h.assert_near(detect.activity(tracks, OPTS, 1)[1], 5)
end

function T.mic_tracks_are_weighted_down()
  -- Talking between takes is loudest exactly where silence is wanted.
  local tracks = {
    { frames = { -20 }, floor_db = -60, live = true, is_mic = true },
  }
  h.assert_near(detect.activity(tracks, OPTS, 1)[1], 40 * 0.35)
end

function T.frames_with_no_media_on_any_live_track_are_false()
  local tracks = {
    { frames = { false, -20 }, floor_db = -60, live = true, is_mic = false },
  }
  local a = detect.activity(tracks, OPTS, 2)
  h.assert_eq(a[1], false)
  h.assert_near(a[2], 40)
end

function T.two_takes_separated_by_a_long_gap()
  -- 60 s take, 10 s of silence, 60 s take.
  local total = 130 * RATE
  local tracks = { {
    frames = track_frames(total, -60, -20, { { 0, 60 }, { 70, 130 } }),
    floor_db = -60, live = true, is_mic = false,
  } }
  local activity = detect.activity(tracks, OPTS, total)
  local takes = detect.takes(activity, { { start = 0, stop = 130 } }, 0, RATE, OPTS)
  h.assert_eq(#takes, 2, "take count")
  h.assert_near(takes[1].start, 0, 0.1)
  h.assert_near(takes[1].stop, 60.5, 0.1)
  h.assert_near(takes[2].start, 69.5, 0.1)
  h.assert_near(takes[2].stop, 130, 0.1)
end

function T.a_short_gap_does_not_split_a_take()
  -- 2 s of silence mid-song is a breakdown, not a take boundary.
  local total = 130 * RATE
  local tracks = { {
    frames = track_frames(total, -60, -20, { { 0, 60 }, { 62, 130 } }),
    floor_db = -60, live = true, is_mic = false,
  } }
  local activity = detect.activity(tracks, OPTS, total)
  local takes = detect.takes(activity, { { start = 0, stop = 130 } }, 0, RATE, OPTS)
  h.assert_eq(#takes, 1, "take count")
end

function T.noodling_shorter_than_min_take_is_discarded()
  -- 10 s of tuning, long gap, then a real 60 s take.
  local total = 130 * RATE
  local tracks = { {
    frames = track_frames(total, -60, -20, { { 0, 10 }, { 60, 125 } }),
    floor_db = -60, live = true, is_mic = false,
  } }
  local activity = detect.activity(tracks, OPTS, total)
  local takes = detect.takes(activity, { { start = 0, stop = 130 } }, 0, RATE, OPTS)
  h.assert_eq(#takes, 1, "take count")
  h.assert_near(takes[1].start, 59.5, 0.2)
end

function T.a_take_never_spans_a_hard_cut()
  -- Continuous audio across what the timeline says is a stop/start. Detection
  -- must obey the item boundary regardless of what the amplitude says.
  local total = 130 * RATE
  local tracks = { {
    frames = track_frames(total, -60, -20, { { 0, 130 } }),
    floor_db = -60, live = true, is_mic = false,
  } }
  local activity = detect.activity(tracks, OPTS, total)
  local spans = { { start = 0, stop = 60 }, { start = 60, stop = 130 } }
  local takes = detect.takes(activity, spans, 0, RATE, OPTS)
  h.assert_eq(#takes, 2, "take count")
  h.assert_eq(takes[1].span_index, 1)
  h.assert_eq(takes[2].span_index, 2)
end

function T.padding_is_clamped_to_the_covered_span()
  -- A take filling its span must not be padded past the item edge.
  local total = 60 * RATE
  local tracks = { {
    frames = track_frames(total, -60, -20, { { 0, 60 } }),
    floor_db = -60, live = true, is_mic = false,
  } }
  local activity = detect.activity(tracks, OPTS, total)
  local takes = detect.takes(activity, { { start = 0, stop = 60 } }, 0, RATE, OPTS)
  h.assert_eq(#takes, 1, "take count")
  h.assert_near(takes[1].start, 0, 1e-9)
  h.assert_near(takes[1].stop, 60, 1e-9)
end

function T.an_empty_span_yields_no_takes()
  local total = 60 * RATE
  local tracks = { {
    frames = track_frames(total, -60, -20, {}),
    floor_db = -60, live = true, is_mic = false,
  } }
  local activity = detect.activity(tracks, OPTS, total)
  local takes = detect.takes(activity, { { start = 0, stop = 60 } }, 0, RATE, OPTS)
  h.assert_eq(#takes, 0)
end

function T.span_index_is_reported_for_every_take()
  local total = 200 * RATE
  local tracks = { {
    frames = track_frames(total, -60, -20, { { 0, 60 }, { 100, 190 } }),
    floor_db = -60, live = true, is_mic = false,
  } }
  local activity = detect.activity(tracks, OPTS, total)
  local spans = { { start = 0, stop = 60 }, { start = 100, stop = 200 } }
  local takes = detect.takes(activity, spans, 0, RATE, OPTS)
  h.assert_eq(#takes, 2)
  h.assert_eq(takes[1].span_index, 1)
  h.assert_eq(takes[2].span_index, 2)
end

return T
```

- [ ] **Step 2: Register the suite and run to confirm failure**

Extend `SUITES` in `test/run.lua` with `"test.detect_test"`.

Run: `./bin/test`
Expected: FAIL, `module 'lib.detect' not found`.

- [ ] **Step 3: Implement**

```lua
-- lib/detect.lua
-- Finds take boundaries from the combined activity of the live tracks.
--
-- There is no reference track: attendance varies and any instrument may be
-- absent, including drums. Each live track is normalised against its own floor
-- and the maximum is taken per frame, so one instrument playing is enough to
-- register and the detector degrades gracefully as the lineup shrinks.

local frames_util = require("lib.util.frames")

local M = {}

-- tracks    array of { frames = {db|false}, floor_db = , live = , is_mic = }
-- opts      { mic_weight, ... }
-- n_frames  length of the dense analysis array
--
-- Returns a dense array of dB-above-floor numbers, or `false` where no live
-- track has media.
function M.activity(tracks, opts, n_frames)
  local out = {}
  for i = 1, n_frames do
    local best = false
    for _, track in ipairs(tracks) do
      if track.live then
        local v = track.frames[i]
        if v ~= false and v ~= nil then
          local above = v - track.floor_db
          if track.is_mic then above = above * opts.mic_weight end
          if best == false or above > best then best = above end
        end
      end
    end
    out[i] = best
  end
  return out
end

-- Takes are the spans between gaps, intersected with the covered spans. A gap
-- is a run where every live track sits near its floor for at least
-- opts.min_gap_sec.
--
-- Returns an array of { start, stop, span_index }.
function M.takes(activity, covered_spans, sel_start, rate, opts)
  local min_gap_frames = math.max(1, math.floor(opts.min_gap_sec * rate))
  local raw = {}

  for span_index, span in ipairs(covered_spans) do
    local i0 = math.max(1, frames_util.index_of(span.start, sel_start, rate))
    -- Clamp: a span ending exactly at the selection edge indexes one frame past
    -- the array, and comparing nil against a threshold is a hard error.
    local i1 = math.min(#activity, frames_util.index_of(span.stop, sel_start, rate) - 1)
    local run_start, gap_run = nil, 0

    local function close(last_active_frame)
      if run_start then
        raw[#raw + 1] = {
          span_index = span_index,
          start = frames_util.time_of(run_start, sel_start, rate),
          stop = frames_util.time_of(last_active_frame + 1, sel_start, rate),
        }
        run_start = nil
      end
    end

    for i = i0, i1 do
      local a = activity[i]
      local quiet = (a == false) or (a < opts.gap_threshold_db)
      if quiet then
        gap_run = gap_run + 1
        if gap_run == min_gap_frames then close(i - min_gap_frames) end
      else
        gap_run = 0
        if not run_start then run_start = i end
      end
    end
    close(i1)
  end

  local kept = {}
  for _, take in ipairs(raw) do
    if take.stop - take.start >= opts.min_take_sec then
      local span = covered_spans[take.span_index]
      -- Pad outward so nothing clips a count-in or ring-out, but never past an
      -- item edge: a region spanning a hard cut would bake the gap into the
      -- rendered master.
      take.start = math.max(span.start, take.start - opts.pad_sec)
      take.stop = math.min(span.stop, take.stop + opts.pad_sec)
      assert(take.start >= span.start - 1e-6 and take.stop <= span.stop + 1e-6,
        "take escaped its covered span — this is a bug, not a tuning problem")
      kept[#kept + 1] = take
    end
  end

  return kept
end

return M
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `./bin/test`
Expected: `37 passed, 0 failed`.

If any boundary assertion is off by one frame (0.05 s at 20 Hz), fix `lib/util/frames.lua` or the `close()` arithmetic — do not loosen the test tolerances, which are already 0.1 s.

- [ ] **Step 5: Commit**

```bash
git add lib/detect.lua test/detect_test.lua test/run.lua
git commit -m "Add take boundary detection from combined track activity"
```

---

### Task 6: Per-take instrument presence

Which live tracks actually carry signal inside a given take. Nearly free once liveness has run, and it varies within a session — a player arrives late, someone sits a tune out — so it is computed per take, never per session.

**Files:**
- Create: `lib/presence.lua`
- Create: `test/presence_test.lua`
- Modify: `test/run.lua`

**Interfaces:**
- Consumes: `lib.util.frames`
- Produces: `presence.instruments_in(tracks, span, sel_start, rate, opts) -> array of string`, ordered as `tracks` is. Each track element additionally carries `slug` (string or nil) and `name` (string); the slug is used when present, the track name otherwise.

- [ ] **Step 1: Write the failing tests**

```lua
-- test/presence_test.lua
local h = require("test.helpers")
local presence = require("lib.presence")

local T = {}

local RATE = 20
local OPTS = { live_margin_db = 12, presence_min_fraction = 0.05 }

local function frames_at(total, quiet, loud, loud_ranges)
  local out = {}
  for i = 1, total do out[i] = quiet end
  for _, r in ipairs(loud_ranges or {}) do
    for i = math.floor(r[1] * RATE) + 1, math.floor(r[2] * RATE) do
      out[i] = loud
    end
  end
  return out
end

function T.reports_only_tracks_playing_within_the_span()
  local tracks = {
    { name = "BASS DI", slug = "bass", live = true, floor_db = -60,
      frames = frames_at(200 * RATE, -60, -20, { { 0, 100 } }) },
    { name = "TRUMPET", slug = "trumpet", live = true, floor_db = -60,
      frames = frames_at(200 * RATE, -60, -20, { { 100, 200 } }) },
  }
  local first = presence.instruments_in(
    tracks, { start = 0, stop = 100 }, 0, RATE, OPTS)
  h.assert_eq(#first, 1)
  h.assert_eq(first[1], "bass")

  local second = presence.instruments_in(
    tracks, { start = 100, stop = 200 }, 0, RATE, OPTS)
  h.assert_eq(#second, 1)
  h.assert_eq(second[1], "trumpet")
end

function T.absent_tracks_are_never_reported()
  local tracks = {
    { name = "KEYS", slug = "keys", live = false, floor_db = -60,
      frames = frames_at(100 * RATE, -60, -20, { { 0, 100 } }) },
  }
  local got = presence.instruments_in(
    tracks, { start = 0, stop = 100 }, 0, RATE, OPTS)
  h.assert_eq(#got, 0)
end

function T.a_brief_stab_below_the_fraction_does_not_count()
  -- Two seconds of signal in a 100-second take is 2%, under the 5% floor.
  local tracks = {
    { name = "SAX", slug = "sax", live = true, floor_db = -60,
      frames = frames_at(100 * RATE, -60, -20, { { 0, 2 } }) },
  }
  local got = presence.instruments_in(
    tracks, { start = 0, stop = 100 }, 0, RATE, OPTS)
  h.assert_eq(#got, 0)
end

function T.track_name_is_used_when_no_slug_is_mapped()
  local tracks = {
    { name = "NEW MIC 4", slug = nil, live = true, floor_db = -60,
      frames = frames_at(100 * RATE, -60, -20, { { 0, 100 } }) },
  }
  local got = presence.instruments_in(
    tracks, { start = 0, stop = 100 }, 0, RATE, OPTS)
  h.assert_eq(got[1], "NEW MIC 4")
end

function T.frames_with_no_media_do_not_count_against_presence()
  -- A player whose item covers only the second half of the take is present,
  -- judged over the frames where they actually have media.
  local f = frames_at(100 * RATE, -20, -20, {})
  for i = 1, 50 * RATE do f[i] = false end
  local tracks = {
    { name = "GTR", slug = "gtr", live = true, floor_db = -60, frames = f },
  }
  local got = presence.instruments_in(
    tracks, { start = 0, stop = 100 }, 0, RATE, OPTS)
  h.assert_eq(got[1], "gtr")
end

return T
```

- [ ] **Step 2: Register the suite and run to confirm failure**

Extend `SUITES` in `test/run.lua` with `"test.presence_test"`.

Run: `./bin/test`
Expected: FAIL, `module 'lib.presence' not found`.

- [ ] **Step 3: Implement**

```lua
-- lib/presence.lua
-- Which live tracks actually carry signal inside a given take.
--
-- This is the `instruments` field the downstream contract wants: what was
-- played and captured on this take, which is deliberately not the same as
-- which stems exist. It varies within a session, so it is computed per take.

local frames_util = require("lib.util.frames")

local M = {}

-- tracks  array of { frames, floor_db, live, name, slug }
-- span    { start, stop }
-- opts    { live_margin_db, presence_min_fraction }
--
-- Returns slugs (or track names where unmapped), in track order.
function M.instruments_in(tracks, span, sel_start, rate, opts)
  local i0 = frames_util.index_of(span.start, sel_start, rate)
  local i1 = frames_util.index_of(span.stop, sel_start, rate)

  local out = {}
  for _, track in ipairs(tracks) do
    if track.live then
      local threshold = track.floor_db + opts.live_margin_db
      local total, active = 0, 0
      for i = i0, i1 do
        local v = track.frames[i]
        if v ~= false and v ~= nil then
          total = total + 1
          if v > threshold then active = active + 1 end
        end
      end
      if total > 0 and active / total > opts.presence_min_fraction then
        out[#out + 1] = track.slug or track.name
      end
    end
  end
  return out
end

return M
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `./bin/test`
Expected: `42 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add lib/presence.lua test/presence_test.lua test/run.lua
git commit -m "Add per-take instrument presence detection"
```

---

### Task 7: Configuration

One file holds paths, thresholds, the track-to-slug mapping and the songs list. It is copied from a tracked example on first run and gitignored thereafter, so the operator's repertoire and lineup never enter the repository.

**Files:**
- Create: `lib/util/json.lua` (vendored)
- Create: `lib/config.lua`
- Create: `config/settings.example.json`
- Create: `test/config_test.lua`
- Modify: `test/run.lua`

**Interfaces:**
- Consumes: `lib.util.json`
- Produces:
  - `config.defaults() -> table` — the full default tree.
  - `config.merge(defaults, loaded) -> table` — recursive, loaded wins per leaf.
  - `config.expand_path(path, home) -> string` — expands a leading `~`; `home` defaults to `$HOME` and is passed explicitly by tests.
  - `config.match_track(name, rules) -> rule|nil` — exact, then substring, in rule order.
  - `config.load(dir, io_read) -> table, bool` — returns the merged config and whether it fell back to the example. `io_read` is a function taking a path and returning contents or nil, injected so this is testable without touching disk.

- [ ] **Step 1: Vendor dkjson**

```bash
mkdir -p lib/util
curl -fsSL http://dkolf.de/dkjson-lua/dkjson.lua -o lib/util/json.lua
head -5 lib/util/json.lua
/opt/homebrew/opt/lua@5.4/bin/lua -e 'local j=dofile("lib/util/json.lua"); print(j.encode({a=1}))'
```

Expected: prints `{"a":1}`. dkjson is MIT-licensed; leave its header comment intact.

- [ ] **Step 2: Write the example configuration**

```json
{
  "sessionsRoot": "~/Music/RehearsalSessions",
  "render": { "format": "opus", "bitrateKbps": 128, "stems": true },
  "detection": {
    "frameRateHz": 20,
    "floorPercentile": 10,
    "liveMarginDb": 12,
    "liveMinFraction": 0.02,
    "micWeight": 0.35,
    "gapThresholdDb": 6,
    "minGapSec": 4.0,
    "minTakeSec": 30.0,
    "padSec": 0.5,
    "presenceMinFraction": 0.05,
    "snapToMeasure": false
  },
  "tracks": [
    { "match": "BASS DI", "slug": "bass", "isMic": false },
    { "match": "DRUMS", "slug": "drums", "isMic": false },
    { "match": "VOX", "slug": "vox-lead", "isMic": true }
  ],
  "songs": [
    { "title": "Example Song", "aliases": ["example"] }
  ]
}
```

- [ ] **Step 3: Write the failing tests**

```lua
-- test/config_test.lua
local h = require("test.helpers")
local config = require("lib.config")

local T = {}

function T.defaults_cover_every_detection_tunable()
  local d = config.defaults()
  h.assert_eq(d.detection.frameRateHz, 20)
  h.assert_eq(d.detection.minGapSec, 4.0)
  h.assert_eq(d.detection.minTakeSec, 30.0)
  h.assert_eq(d.detection.micWeight, 0.35)
  h.assert_eq(d.detection.snapToMeasure, false)
end

function T.merge_overrides_only_the_leaves_given()
  local merged = config.merge(
    config.defaults(), { detection = { minGapSec = 2.5 } })
  h.assert_eq(merged.detection.minGapSec, 2.5)
  h.assert_eq(merged.detection.minTakeSec, 30.0, "untouched leaf preserved")
end

function T.merge_replaces_arrays_wholesale()
  -- Merging arrays element-wise would make it impossible to remove a track rule.
  local merged = config.merge(
    config.defaults(), { tracks = { { match = "ONLY", slug = "x" } } })
  h.assert_eq(#merged.tracks, 1)
  h.assert_eq(merged.tracks[1].match, "ONLY")
end

function T.expand_path_expands_a_leading_tilde()
  local expanded = config.expand_path("~/Music/X", "/Users/example")
  h.assert_eq(expanded, "/Users/example/Music/X")
end

function T.expand_path_leaves_absolute_paths_alone()
  h.assert_eq(config.expand_path("/tmp/x", "/Users/example"), "/tmp/x")
end

function T.match_track_prefers_an_exact_name()
  local rules = {
    { match = "BASS", slug = "wrong" },
    { match = "BASS DI 2", slug = "right" },
  }
  h.assert_eq(config.match_track("BASS DI 2", rules).slug, "right")
end

function T.match_track_falls_back_to_substring()
  local rules = { { match = "BASS", slug = "bass" } }
  h.assert_eq(config.match_track("BASS DI 2", rules).slug, "bass")
end

function T.match_track_is_case_insensitive()
  local rules = { { match = "bass di", slug = "bass" } }
  h.assert_eq(config.match_track("BASS DI 2", rules).slug, "bass")
end

function T.match_track_returns_nil_when_unmapped()
  local rules = { { match = "BASS", slug = "bass" } }
  h.assert_eq(config.match_track("NEW MIC 4", rules), nil)
end

function T.load_falls_back_to_the_example_when_settings_are_missing()
  local reads = {}
  local function fake_read(path)
    reads[#reads + 1] = path
    if path:match("example") then
      return '{"sessionsRoot":"/from/example"}'
    end
    return nil
  end
  local cfg, used_example = config.load("/repo", fake_read)
  h.assert_eq(used_example, true)
  h.assert_eq(cfg.sessionsRoot, "/from/example")
end

function T.load_prefers_settings_over_the_example()
  local function fake_read(path)
    if path:match("example") then return '{"sessionsRoot":"/from/example"}' end
    return '{"sessionsRoot":"/from/settings"}'
  end
  local cfg, used_example = config.load("/repo", fake_read)
  h.assert_eq(used_example, false)
  h.assert_eq(cfg.sessionsRoot, "/from/settings")
end

return T
```

- [ ] **Step 4: Register the suite and run to confirm failure**

Extend `SUITES` in `test/run.lua` with `"test.config_test"`.

Run: `./bin/test`
Expected: FAIL, `module 'lib.config' not found`.

- [ ] **Step 5: Implement**

```lua
-- lib/config.lua
-- Loads config/settings.json, falling back to config/settings.example.json.
--
-- The `tracks` array does double duty on purpose: the same entry supplies the
-- instrument slug for stem naming and the isMic flag that suppresses between-
-- take chatter in gap detection. Both answer one question — what is this
-- track, musically — so splitting them would mean maintaining the lineup twice.

local json = require("lib.util.json")

local M = {}

function M.defaults()
  return {
    sessionsRoot = "~/Music/RehearsalSessions",
    render = { format = "opus", bitrateKbps = 128, stems = true },
    detection = {
      frameRateHz = 20,
      floorPercentile = 10,
      liveMarginDb = 12,
      liveMinFraction = 0.02,
      micWeight = 0.35,
      gapThresholdDb = 6,
      minGapSec = 4.0,
      minTakeSec = 30.0,
      padSec = 0.5,
      presenceMinFraction = 0.05,
      snapToMeasure = false,
    },
    tracks = {},
    songs = {},
  }
end

local function is_array(t)
  return type(t) == "table" and (#t > 0 or next(t) == nil)
end

-- Recursive merge. Arrays are replaced wholesale, never merged element-wise:
-- merging them would make removing a track rule impossible.
function M.merge(base, override)
  if type(override) ~= "table" then
    if override == nil then return base end
    return override
  end
  if is_array(override) and #override > 0 then return override end

  local out = {}
  for k, v in pairs(base) do out[k] = v end
  for k, v in pairs(override) do
    if type(v) == "table" and type(base[k]) == "table" then
      out[k] = M.merge(base[k], v)
    else
      out[k] = v
    end
  end
  return out
end

function M.expand_path(path, home)
  home = home or os.getenv("HOME") or ""
  local rest = path:match("^~/(.*)$")
  if rest then return home .. "/" .. rest end
  return path
end

-- Exact name match first, then substring, both case-insensitive, in rule order.
-- A fuzzy pass is deliberately absent here: it needs operator confirmation,
-- which belongs in the panel (milestone 3), not in a silent loader.
function M.match_track(name, rules)
  local lowered = name:lower()
  for _, rule in ipairs(rules) do
    if lowered == rule.match:lower() then return rule end
  end
  for _, rule in ipairs(rules) do
    if lowered:find(rule.match:lower(), 1, true) then return rule end
  end
  return nil
end

-- read_file(path) -> string|nil, injected so this is testable without disk.
-- Returns the merged config and whether it fell back to the example.
function M.load(dir, read_file)
  local settings = read_file(dir .. "/config/settings.json")
  local used_example = false
  if not settings then
    settings = read_file(dir .. "/config/settings.example.json")
    used_example = true
  end
  if not settings then
    error("no config found in " .. dir .. "/config/")
  end
  local parsed, _, err = json.decode(settings)
  if not parsed then
    error("config is not valid JSON: " .. tostring(err))
  end
  return M.merge(M.defaults(), parsed), used_example
end

return M
```

- [ ] **Step 6: Run the tests and confirm they pass**

Run: `./bin/test`
Expected: `53 passed, 0 failed`.

- [ ] **Step 7: Commit**

```bash
git add lib/config.lua lib/util/json.lua config/settings.example.json test/config_test.lua test/run.lua
git commit -m "Add configuration loading with example fallback"
```

---

### Task 8: REAPER adapter

The only file that touches the `reaper` global. It turns the current project and time selection into the plain arrays every `lib/` module expects.

**Files:**
- Create: `adapters/reaper_api.lua`
- Modify: `docs/notes/reascript-findings.md` (correct it if behaviour differs from Task 1's record)

**Interfaces:**
- Consumes: `lib.util.frames`, `lib.config`
- Produces:
  - `adapter.time_selection() -> start, stop` (nil, nil if empty)
  - `adapter.collect(sel_start, sel_stop, rate, track_rules) -> tracks, items` where each track is `{ guid, name, slug, is_mic, items = {{start, stop}}, frames = {db|false} }` and `items` is the flattened union of every track's item extents, ready for `timeline.covered_spans`.
  - `adapter.read_file(path) -> string|nil`
  - `adapter.script_dir() -> string`
  - `adapter.log(fmt, ...)`

- [ ] **Step 1: Implement the adapter**

Write this against the behaviour recorded in `docs/notes/reascript-findings.md`. The `starttime` argument below assumes it is **source time**, which is why `D_STARTOFFS` is added. If Task 1 observed item-relative time, change the marked line to pass `0` and record the correction in the findings file.

```lua
-- adapters/reaper_api.lua
-- The only file in this project permitted to touch the `reaper` global.
-- Everything under lib/ receives plain arrays so it can be tested on the CLI.

local frames_util = require("lib.util.frames")
local config = require("lib.config")

local M = {}

function M.log(fmt, ...)
  reaper.ShowConsoleMsg(string.format(fmt .. "\n", ...))
end

function M.read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local contents = f:read("*a")
  f:close()
  return contents
end

function M.script_dir()
  local _, filename = reaper.get_action_context()
  return filename:match("^(.*)[/\\][^/\\]*$")
end

function M.time_selection()
  local start, stop = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if stop <= start then return nil, nil end
  return start, stop
end

-- Converts a linear peak amplitude to dB, with a floor well below any real
-- signal so log(0) never appears.
local function to_db(amplitude)
  if amplitude < 1e-7 then return -140 end
  return 20 * math.log(amplitude, 10)
end

-- Fills `frames` for one take. Positions with no media are left untouched, so
-- the caller's `false` initialisation stands: a hard cut must never read as 0.
local function read_take_peaks(take, item_start, item_stop, sel_start, rate, frames)
  local source = reaper.GetMediaItemTake_Source(take)
  local channels = reaper.GetMediaSourceNumChannels(source)
  if channels < 1 then return end

  local start_offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local n = math.max(1, frames_util.count(item_start, item_stop, rate))

  local buf = reaper.new_array(channels * n * 2)
  buf.clear()

  -- Marked line: source time. See docs/notes/reascript-findings.md.
  local retval = reaper.GetMediaItemTake_Peaks(
    take, rate, start_offs, channels, n, 0, buf)
  local returned = retval & 0xfffff
  if returned < 1 then return end

  local t = buf.table()
  local mins_offset = returned * channels

  for f = 1, returned do
    local peak = 0
    for ch = 1, channels do
      local hi = math.abs(t[(f - 1) * channels + ch] or 0)
      local lo = math.abs(t[mins_offset + (f - 1) * channels + ch] or 0)
      if hi > peak then peak = hi end
      if lo > peak then peak = lo end
    end
    local absolute_time = item_start + (f - 1) / rate
    local index = frames_util.index_of(absolute_time, sel_start, rate)
    if index >= 1 and index <= #frames then
      local db = to_db(peak)
      local existing = frames[index]
      if existing == false or db > existing then frames[index] = db end
    end
  end
end

-- Returns tracks (with dense frame arrays) and the flattened item extents.
function M.collect(sel_start, sel_stop, rate, track_rules)
  local n_frames = frames_util.count(sel_start, sel_stop, rate)
  local tracks, all_items = {}, {}

  for ti = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, ti)
    local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    local rule = config.match_track(name, track_rules)

    local frames = {}
    for i = 1, n_frames do frames[i] = false end

    local items = {}
    for ii = 0, reaper.CountTrackMediaItems(track) - 1 do
      local item = reaper.GetTrackMediaItem(track, ii)
      local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      local item_start = math.max(pos, sel_start)
      local item_stop = math.min(pos + len, sel_stop)
      if item_stop > item_start then
        items[#items + 1] = { start = item_start, stop = item_stop }
        all_items[#all_items + 1] = { start = item_start, stop = item_stop }
        local take = reaper.GetActiveTake(item)
        if take and not reaper.TakeIsMIDI(take) then
          local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
          if math.abs(playrate - 1.0) > 1e-6 then
            M.log("WARNING: track '%s' item at %.2f has playrate %.3f; "
              .. "peak times will be wrong. Reset it to 1.0.", name, pos, playrate)
          end
          read_take_peaks(take, item_start, item_stop, sel_start, rate, frames)
        end
      end
    end

    tracks[#tracks + 1] = {
      guid = reaper.GetTrackGUID(track),
      name = name,
      slug = rule and rule.slug or nil,
      is_mic = rule and rule.isMic or false,
      items = items,
      frames = frames,
    }
  end

  return tracks, all_items
end

return M
```

- [ ] **Step 2: Verify against the probe's findings**

Re-read `docs/notes/reascript-findings.md`. Confirm the `starttime` argument and the `mins_offset` arithmetic match what was observed. Correct either the code or the findings file so they agree.

- [ ] **Step 3: Commit**

```bash
git add adapters/reaper_api.lua docs/notes/reascript-findings.md
git commit -m "Add REAPER adapter for track and peak collection"
```

---

### Task 9: Dry-run report and action script

The deliverable of this milestone: a report you can argue with. It goes to the REAPER console and to a file, so two threshold settings can be diffed rather than compared by screenshot.

**Files:**
- Create: `lib/report.lua`
- Create: `test/report_test.lua`
- Create: `scripts/Reapertoire_Analyze_dryrun.lua`
- Modify: `test/run.lua`

**Interfaces:**
- Consumes: everything above
- Produces: `report.render(data) -> string` where `data` is `{ sel_start, sel_stop, rate, tracks, covered_spans, takes, warnings, opts }` and each take carries `{ start, stop, span_index, instruments }`.

- [ ] **Step 1: Write the failing tests**

```lua
-- test/report_test.lua
local h = require("test.helpers")
local report = require("lib.report")

local T = {}

local function sample()
  return {
    sel_start = 0, sel_stop = 300, rate = 20,
    tracks = {
      { name = "BASS DI 2", slug = "bass", live = true,
        floor_db = -58.2, active_fraction = 0.41 },
      { name = "KEYS", slug = "keys", live = false,
        floor_db = -61.0, active_fraction = 0.001 },
    },
    covered_spans = {
      { start = 0, stop = 150 },
      { start = 160, stop = 300 },
    },
    takes = {
      { start = 10, stop = 70, span_index = 1, instruments = { "bass" } },
      { start = 165, stop = 290, span_index = 2, instruments = { "bass" } },
    },
    warnings = { "unmapped live track: NEW MIC 4" },
    opts = { minGapSec = 4.0, minTakeSec = 30.0 },
  }
end

function T.reports_absent_tracks_so_the_operator_can_correct_the_heuristic()
  local text = report.render(sample())
  assert(text:find("KEYS"), "absent track not listed")
  assert(text:find("not present"), "absence not stated in words")
end

function T.reports_the_measured_floor_per_track()
  local text = report.render(sample())
  assert(text:find("%-58%.2"), "bass floor not reported")
end

function T.reports_span_count_and_whether_detection_subdivided_each()
  local text = report.render(sample())
  assert(text:find("2 covered spans"), "span count missing")
  -- One take in each span means neither was subdivided.
  assert(text:find("1 take"), "per-span take count missing")
end

function T.reports_each_take_with_duration_and_instruments()
  local text = report.render(sample())
  assert(text:find("0:10"), "take start not formatted as mm:ss")
  assert(text:find("bass"), "instruments missing")
end

function T.surfaces_warnings()
  local text = report.render(sample())
  assert(text:find("NEW MIC 4"), "warning not surfaced")
end

function T.states_plainly_when_nothing_was_detected()
  local data = sample()
  data.takes = {}
  local text = report.render(data)
  assert(text:find("No takes detected"), "empty result not stated")
end

return T
```

- [ ] **Step 2: Register the suite and run to confirm failure**

Extend `SUITES` in `test/run.lua` with `"test.report_test"`.

Run: `./bin/test`
Expected: FAIL, `module 'lib.report' not found`.

- [ ] **Step 3: Implement the report**

```lua
-- lib/report.lua
-- Renders the dry-run report. Written to both the REAPER console and a file so
-- two threshold settings can be diffed rather than compared by screenshot.

local M = {}

local function mmss(t)
  local minutes = math.floor(t / 60)
  local seconds = t - minutes * 60
  return string.format("%d:%05.2f", minutes, seconds)
end

function M.render(data)
  local out = {}
  local function line(fmt, ...)
    out[#out + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt
  end

  line("Reapertoire dry run")
  line("Selection: %s to %s (%.1f s) at %d Hz",
    mmss(data.sel_start), mmss(data.sel_stop),
    data.sel_stop - data.sel_start, data.rate)
  line("Thresholds: minGapSec=%.1f minTakeSec=%.1f",
    data.opts.minGapSec, data.opts.minTakeSec)
  line("")

  line("Tracks")
  for _, t in ipairs(data.tracks) do
    if t.live then
      line("  %-16s live         floor %.1f dB, active %.1f%%%s",
        t.name, t.floor_db or 0, (t.active_fraction or 0) * 100,
        t.slug and "" or "   [UNMAPPED]")
    else
      line("  %-16s not present  floor %s dB",
        t.name, t.floor_db and string.format("%.1f", t.floor_db) or "n/a")
    end
  end
  line("")

  line("Timeline: %d covered spans", #data.covered_spans)
  for i, span in ipairs(data.covered_spans) do
    local n = 0
    for _, take in ipairs(data.takes) do
      if take.span_index == i then n = n + 1 end
    end
    line("  span %d  %s - %s (%.1f s)  %d take%s%s",
      i, mmss(span.start), mmss(span.stop), span.stop - span.start,
      n, n == 1 and "" or "s",
      n > 1 and "  [subdivided]" or "")
  end
  line("")

  if #data.takes == 0 then
    line("No takes detected. Lower minTakeSec or gapThresholdDb and re-run.")
  else
    line("Takes")
    for i, take in ipairs(data.takes) do
      line("  %2d  %s - %s  %5.1f s  span %d  %s",
        i, mmss(take.start), mmss(take.stop), take.stop - take.start,
        take.span_index, table.concat(take.instruments, ", "))
    end
  end

  if #data.warnings > 0 then
    line("")
    line("Warnings")
    for _, w in ipairs(data.warnings) do line("  %s", w) end
  end

  return table.concat(out, "\n") .. "\n"
end

return M
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `./bin/test`
Expected: `59 passed, 0 failed`.

- [ ] **Step 5: Write the action script**

```lua
-- scripts/Reapertoire_Analyze_dryrun.lua
-- Milestone 1 deliverable. Reports what it found and writes nothing to the
-- project: no regions, no markers, no sidecar.

local script_path = ({ reaper.get_action_context() })[2]
local repo_dir = script_path:match("^(.*)[/\\]scripts[/\\][^/\\]*$")
package.path = repo_dir .. "/?.lua;" .. repo_dir .. "/?/init.lua;" .. package.path

local adapter = require("adapters.reaper_api")
local config = require("lib.config")
local frames_util = require("lib.util.frames")
local timeline = require("lib.timeline")
local liveness = require("lib.liveness")
local detect = require("lib.detect")
local presence = require("lib.presence")
local report = require("lib.report")

reaper.ClearConsole()

local cfg, used_example = config.load(repo_dir, adapter.read_file)
if used_example then
  adapter.log("No config/settings.json found — using the tracked example. "
    .. "Copy it to config/settings.json and edit it.")
end

local sel_start, sel_stop = adapter.time_selection()
if not sel_start then
  adapter.log("No time selection. Select a range and run again.")
  return
end

local d = cfg.detection
local rate = d.frameRateHz
local warnings = {}

local tracks, items = adapter.collect(sel_start, sel_stop, rate, cfg.tracks)

for _, track in ipairs(tracks) do
  local result = liveness.classify(track.frames, {
    floor_percentile = d.floorPercentile,
    live_margin_db = d.liveMarginDb,
    live_min_fraction = d.liveMinFraction,
  })
  track.live = result.live
  track.floor_db = result.floor_db
  track.active_fraction = result.active_fraction
  if track.live and not track.slug then
    warnings[#warnings + 1] = "unmapped live track: " .. track.name
      .. " — add a rule to config/settings.json"
  end
end

local covered_spans = timeline.covered_spans(items, sel_start, sel_stop, 0.05)

local n_frames = frames_util.count(sel_start, sel_stop, rate)
local activity = detect.activity(tracks, { mic_weight = d.micWeight }, n_frames)

local takes = detect.takes(activity, covered_spans, sel_start, rate, {
  gap_threshold_db = d.gapThresholdDb,
  min_gap_sec = d.minGapSec,
  min_take_sec = d.minTakeSec,
  pad_sec = d.padSec,
})

for _, take in ipairs(takes) do
  take.instruments = presence.instruments_in(tracks, take, sel_start, rate, {
    live_margin_db = d.liveMarginDb,
    presence_min_fraction = d.presenceMinFraction,
  })
end

local text = report.render({
  sel_start = sel_start, sel_stop = sel_stop, rate = rate,
  tracks = tracks, covered_spans = covered_spans, takes = takes,
  warnings = warnings, opts = d,
})

adapter.log("%s", text)

local project_path = reaper.GetProjectPath()
local out_path = project_path .. "/reapertoire-dryrun.txt"
local f = io.open(out_path, "w")
if f then
  f:write(text)
  f:close()
  adapter.log("Report written to %s", out_path)
else
  adapter.log("Could not write report to %s", out_path)
end
```

- [ ] **Step 6: Run it in REAPER**

Load `scripts/Reapertoire_Analyze_dryrun.lua` from the action list, make a time selection over a real rehearsal, and run. Confirm the console shows a track list, a span count, and takes — and that no regions appeared in the project.

- [ ] **Step 7: Commit**

```bash
git add lib/report.lua test/report_test.lua scripts/Reapertoire_Analyze_dryrun.lua test/run.lua
git commit -m "Add dry-run report and analysis action script"
```

---

### Task 10: Fixture capture and threshold tuning

Every default in the spec is a guess. This task turns real recordings into permanent regression cases and then moves the numbers until the report matches what the ear says.

**Files:**
- Create: `tools/capture_fixture.lua`
- Create: `test/fixtures/` (contents from real sessions)
- Create: `test/fixtures_test.lua`
- Modify: `config/settings.example.json` (tuned defaults)
- Modify: `test/run.lua`
- Create: `README.md`

**Interfaces:**
- Consumes: `adapters.reaper_api`, `lib.config`
- Produces: fixture JSON files shaped `{ selStart, selStop, rate, tracks: [{ name, slug, isMic, frames }], items: [{ start, stop }], expected: { takeCount, spanCount } }`.

- [ ] **Step 1: Write the capture tool**

```lua
-- tools/capture_fixture.lua
-- Dumps the frame energies of the current time selection to a JSON fixture, so
-- threshold experiments run on the CLI in under a second instead of requiring
-- REAPER. Name fixtures for the SCENARIO, never for the band or the songs.

local script_path = ({ reaper.get_action_context() })[2]
local repo_dir = script_path:match("^(.*)[/\\]tools[/\\][^/\\]*$")
package.path = repo_dir .. "/?.lua;" .. repo_dir .. "/?/init.lua;" .. package.path

local adapter = require("adapters.reaper_api")
local config = require("lib.config")
local json = require("lib.util.json")

reaper.ClearConsole()

local cfg = config.load(repo_dir, adapter.read_file)
local rate = cfg.detection.frameRateHz

local sel_start, sel_stop = adapter.time_selection()
if not sel_start then
  adapter.log("No time selection. Select a range and run again.")
  return
end

local ok, name = reaper.GetUserInputs(
  "Capture fixture", 1,
  "Scenario name (no band or song names!),extrawidth=200",
  "full-band")
if not ok then return end

local tracks, items = adapter.collect(sel_start, sel_stop, rate, cfg.tracks)

local out_tracks = {}
for _, t in ipairs(tracks) do
  out_tracks[#out_tracks + 1] = {
    name = t.name, slug = t.slug, isMic = t.is_mic, frames = t.frames,
  }
end

local fixture = {
  selStart = sel_start, selStop = sel_stop, rate = rate,
  tracks = out_tracks, items = items,
  expected = { takeCount = 0, spanCount = 0 },
}

local path = repo_dir .. "/test/fixtures/fixture-" .. name .. ".json"
local f = io.open(path, "w")
f:write(json.encode(fixture, { indent = false }))
f:close()

adapter.log("Wrote %s", path)
adapter.log("Now count the real takes by ear and set expected.takeCount.")
```

Note: track *names* land in the fixture. If a track name identifies the band, rename the track in REAPER before capturing, or edit the name out of the fixture afterwards.

- [ ] **Step 2: Capture fixtures from real sessions**

The spec requires at least three, covering different failure modes:

- `fixture-full-band.json` — everyone present, continuous recording.
- `fixture-missing-drums.json` — a session with a different lineup, ideally with no drums, to prove nothing depends on a reference track.
- `fixture-stop-start.json` — a session where the operator stopped and restarted, producing hard cuts.

For each, listen through and record the true number of takes in `expected.takeCount`, and the true number of covered spans in `expected.spanCount`.

- [ ] **Step 3: Write the fixture regression test**

```lua
-- test/fixtures_test.lua
-- Runs the real pipeline over captured recordings. These are the tests that
-- actually decide whether the thresholds are right.

local h = require("test.helpers")
local json = require("lib.util.json")
local timeline = require("lib.timeline")
local liveness = require("lib.liveness")
local detect = require("lib.detect")
local config = require("lib.config")
local frames_util = require("lib.util.frames")

local FIXTURES = {
  "fixture-full-band",
  "fixture-missing-drums",
  "fixture-stop-start",
}

local function load_fixture(name)
  local f = io.open("test/fixtures/" .. name .. ".json", "r")
  if not f then return nil end
  local contents = f:read("*a")
  f:close()
  return json.decode(contents)
end

local function run_pipeline(fx)
  local d = config.defaults().detection
  local rate = fx.rate

  local tracks = {}
  for _, t in ipairs(fx.tracks) do
    local result = liveness.classify(t.frames, {
      floor_percentile = d.floorPercentile,
      live_margin_db = d.liveMarginDb,
      live_min_fraction = d.liveMinFraction,
    })
    tracks[#tracks + 1] = {
      name = t.name, slug = t.slug, is_mic = t.isMic, frames = t.frames,
      live = result.live, floor_db = result.floor_db,
    }
  end

  local spans = timeline.covered_spans(fx.items, fx.selStart, fx.selStop, 0.05)
  local n = frames_util.count(fx.selStart, fx.selStop, rate)
  local activity = detect.activity(tracks, { mic_weight = d.micWeight }, n)
  local takes = detect.takes(activity, spans, fx.selStart, rate, {
    gap_threshold_db = d.gapThresholdDb,
    min_gap_sec = d.minGapSec,
    min_take_sec = d.minTakeSec,
    pad_sec = d.padSec,
  })
  return tracks, spans, takes
end

local T = {}

for _, name in ipairs(FIXTURES) do
  T["takes_detected_in_" .. name:gsub("-", "_")] = function()
    local fx = load_fixture(name)
    if not fx then
      print("  SKIP " .. name .. " (not captured yet)")
      return
    end
    local _, spans, takes = run_pipeline(fx)
    h.assert_eq(#spans, fx.expected.spanCount, name .. " span count")
    h.assert_eq(#takes, fx.expected.takeCount, name .. " take count")
  end
end

T.no_take_ever_spans_a_hard_cut = function()
  for _, name in ipairs(FIXTURES) do
    local fx = load_fixture(name)
    if fx then
      local _, spans, takes = run_pipeline(fx)
      for _, take in ipairs(takes) do
        local span = spans[take.span_index]
        assert(take.start >= span.start - 1e-6 and take.stop <= span.stop + 1e-6,
          name .. ": take escaped its covered span")
      end
    end
  end
end

return T
```

- [ ] **Step 4: Register the suite and tune**

Extend `SUITES` in `test/run.lua` with `"test.fixtures_test"`.

Run: `./bin/test`

Expect failures. This is the tuning loop, and it is the point of the milestone:

- **Too many takes** — a song is being split at a breakdown or a between-verse stop. Raise `minGapSec`, or raise `gapThresholdDb` if room noise is registering as activity.
- **Too few takes** — two songs are being joined. Lower `minGapSec`. If they run back-to-back with no pause at all, no threshold will help; that is the medley case and it needs the manual split in milestone 3. Record which fixture this applies to in the fixture's `expected` block as a comment field rather than chasing it.
- **A track misclassified as absent** — lower `liveMinFraction`, or `liveMarginDb` if the player is quiet.
- **Chatter registering as a take** — lower `micWeight`, or check that the mic track has an `isMic` rule in the config.

Change one number at a time and re-run. When all three fixtures pass, copy the tuned values into `config/settings.example.json` and into `config.defaults()`.

- [ ] **Step 5: Write the README**

```markdown
# Reapertoire

Finds, names and renders takes from multitrack rehearsal recordings in REAPER.

Marking and naming takes is the tedious part of keeping rehearsal recordings —
finding where each run-through starts and stops in an hour of audio, and
labelling which song it was. Reapertoire does the finding, and reduces the
labelling to a few keystrokes.

## Status

Milestone 1: analysis and dry run. It reports what it found and writes nothing
to your project.

## Requirements

- REAPER 7 (developed against 7.42)
- Lua 5.4 for running the tests: `brew install lua@5.4`

## Install

Symlink this checkout into REAPER's `Scripts/` directory, then load
`scripts/Reapertoire_Analyze_dryrun.lua` from the action list.

## Configure

    cp config/settings.example.json config/settings.json

Edit `config/settings.json`: it holds your output path, detection thresholds,
the mapping from REAPER track names to instrument slugs, and your song list.
It is gitignored, so your repertoire and lineup stay out of the repository.

## Use

Make a time selection over a rehearsal and run the analyse action. It prints a
report and writes the same text next to your project file.

Every threshold default is a starting point. Capture a fixture from a real
session with `tools/capture_fixture.lua` and tune against it — the tests run in
under a second, unlike a round trip through REAPER.

## Tests

    ./bin/test

## Licence

MIT.
```

- [ ] **Step 6: Commit**

```bash
git add tools/capture_fixture.lua test/fixtures test/fixtures_test.lua test/run.lua config/settings.example.json lib/config.lua README.md
git commit -m "Add fixture capture, regression tests and tuned thresholds"
```

---

## Deliberately not in this milestone

`snapToMeasure` exists in the configuration but is not implemented here. Snapping
matters when a region boundary is created, not when a span is reported, so it
belongs in milestone 2. It ships `false` regardless — project tempo is unlikely
to be meaningful on a live-tracked rehearsal, and a wrong snap moves a boundary
already verified by ear.

## Done when

- `./bin/test` passes, including all three real-session fixtures.
- The analyse action produces a report on a real rehearsal whose take count matches what you hear.
- No regions, markers or sidecar files are created by anything in this milestone.
- `git grep -inE '<private-band-name>|<private-server-name>' -- lib adapters scripts tools config test README.md` returns nothing. (Scoped to code so this plan's own reminder does not match itself.)

Milestone 2 (region creation from a span list) starts from here.
