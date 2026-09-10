-- adapters/recognise.lua
-- Runs the song-recognition sidecar.
--
-- Out of process on purpose: the numeric work needs librosa and numpy, which do
-- not belong in REAPER's embedded Lua, and a crash in that stack must not take
-- the DAW down with it. The two talk JSON over temporary files.

local json = require("lib.util.json")
local background = require("adapters.background")

local M = {}

M.REFERENCES = ".reapertoire-references.json"

local function python(repo_dir)
  return repo_dir .. "/.venv/bin/python"
end

function M.available(repo_dir)
  local f = io.open(python(repo_dir), "r")
  if not f then return false end
  f:close()
  return true
end

-- stderr is folded into the output rather than discarded: a swallowed error
-- here is indistinguishable from the recogniser simply finding nothing, which
-- is the least useful failure mode available.
local function run(command)
  local pipe = io.popen(command .. " 2>&1")
  if not pipe then return nil, "io.popen is unavailable" end
  local out = pipe:read("*a")
  pipe:close()
  return out
end

local function temp_dir()
  return os.getenv("TMPDIR") or "/tmp"
end

-- Renders each region to a short, low-quality file purely for analysis. Chroma
-- and tempo need neither fidelity nor stereo, and a small file keeps the
-- extraction fast.
--
-- `rows` are { key, start, stop }. Returns { key = path }.
function M.render_probes(render, rows, seconds, format)
  local dir = string.format("%s/reapertoire-probe-%d", temp_dir(), os.time())
  reaper.RecursiveCreateDirectory(dir, 0)

  local jobs, meta = {}, {}
  for _, row in ipairs(rows) do
    -- The whole region, not a slice of it. This is the single largest factor
    -- in whether the guess is right: measured over held-out takes, a
    -- twenty-five second excerpt ranks the right song first 74% of the time
    -- and the whole take 97%. A rehearsal take is not homogeneous, and a short
    -- window can land entirely inside one vamp -- every song has a bar of A
    -- minor somewhere. `seconds` is now only a ceiling against a pathological
    -- region; probes render far faster than realtime at 11 kHz mono.
    local length = row.stop - row.start
    local window = math.min(seconds or 600, length)
    local from = row.start + math.max(0, (length - window) / 2)
    jobs[#jobs + 1] = {
      key = row.key, dir = dir, name = tostring(row.key),
      start = from, stop = from + window,
    }
    -- The take's own length, not the excerpt's: it is what the duration
    -- feature compares against the references.
    meta[row.key] = { duration = length, fileSeconds = window }
  end

  local started = reaper.time_precise()
  local paths, failures = render.probe_batch(jobs, format)
  local elapsed = reaper.time_precise() - started

  return dir, paths, failures, meta, elapsed
end

function M.remove_probes(dir)
  local index = 0
  local files = {}
  while true do
    local name = reaper.EnumerateFiles(dir, index)
    if not name then break end
    files[#files + 1] = dir .. "/" .. name
    index = index + 1
  end
  for _, path in ipairs(files) do os.remove(path) end
  os.remove(dir)
end

-- Ranks the reference library against each probe. Returns { key = { {song, score} } }.
function M.match(repo_dir, references_path, paths, meta)
  local takes = {}
  for key, path in pairs(paths) do
    local info = meta and meta[key] or {}
    takes[#takes + 1] = {
      id = tostring(key), path = path,
      duration = info.duration, fileSeconds = info.fileSeconds,
    }
  end
  if #takes == 0 then return {} end

  local input_path = string.format("%s/reapertoire-match-%d.json", temp_dir(), os.time())
  local f = io.open(input_path, "w")
  if not f then return {}, "could not write " .. input_path end
  f:write(json.encode({ takes = takes }))
  f:close()

  local command = string.format(
    "%q %q match --refs %q --input %q",
    python(repo_dir), repo_dir .. "/tools/recognise/recognise.py",
    references_path, input_path)
  local out, popen_error = run(command)
  os.remove(input_path)

  if not out or out == "" then
    return {}, popen_error or "the recogniser produced no output"
  end

  -- The result is the last line: anything the interpreter or ffmpeg printed
  -- along the way comes first and is not JSON.
  local last = out:match("[^\r\n]+%s*$") or out
  local parsed = json.decode(last)
  if type(parsed) ~= "table" or type(parsed.results) ~= "table" then
    return {}, out:gsub("%s+$", ""):sub(-200)
  end

  local results = {}
  for key, ranked in pairs(parsed.results) do
    results[tonumber(key) or key] = ranked
  end
  return results
end

-- Rebuilds the reference library from every named take already rendered.
-- Returns a short summary line, or nil and a reason.
-- The command that rebuilds the reference library, for a caller to run.
--
-- Handed back rather than run here because indexing reads every rendered take
-- in the archive and takes minutes: run down a pipe it freezes REAPER for the
-- duration. `adapters/background` runs it detached; `-u` keeps Python from
-- buffering its progress lines into one lump at the end.
function M.index_command(repo_dir, sessions_root, references_path)
  local q = background.quote
  return string.format("%s -u %s index --sessions-root %s --out %s",
    q(python(repo_dir)), q(repo_dir .. "/tools/recognise/recognise.py"),
    q(sessions_root), q(references_path))
end

-- The JSON summary the indexer prints last, out of the whole output.
--
-- Last line, as in match: the tool reports progress before its summary.
function M.parse_index_summary(out)
  if not out or out == "" then return nil, "the recogniser produced no output" end
  local last = out:match("[^\r\n]+%s*$") or out
  local parsed = json.decode(last)
  if type(parsed) ~= "table" then
    return nil, "unexpected output: " .. out:gsub("%s+$", ""):sub(-160)
  end
  return parsed
end

return M
