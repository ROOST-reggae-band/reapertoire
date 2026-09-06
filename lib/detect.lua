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
  for _, track in ipairs(tracks) do
    assert(#track.frames == n_frames, string.format(
      "track %s has %d frames, expected %d — the frame array must span the whole selection",
      track.name or "?", #track.frames, n_frames))
  end

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
    -- Clamp: a span ending exactly at the selection edge indexes one frame past
    -- the array, and comparing nil against a threshold is a hard error.
    local i0, i1 = frames_util.range_of(span, sel_start, rate, #activity)
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
    close(gap_run > 0 and (i1 - gap_run) or i1)
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
