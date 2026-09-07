-- adapters/recognise.lua
-- Runs the song-recognition sidecar.
--
-- Out of process on purpose: the numeric work needs librosa and numpy, which do
-- not belong in REAPER's embedded Lua, and a crash in that stack must not take
-- the DAW down with it. The two talk JSON over temporary files.

local json = require("lib.util.json")

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

local function run(command)
  local pipe = io.popen(command .. " 2>/dev/null")
  if not pipe then return nil end
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
function M.render_probes(render, rows, seconds)
  local dir = string.format("%s/reapertoire-probe-%d", temp_dir(), os.time())
  reaper.RecursiveCreateDirectory(dir, 0)

  local paths = {}
  for _, row in ipairs(rows) do
    -- A slice from the middle: the opening of a take is often a count-in or
    -- someone still settling, which says little about which song it is.
    local length = row.stop - row.start
    local window = math.min(seconds or 120, length)
    local from = row.start + math.max(0, (length - window) / 2)
    local path = render.take(dir, tostring(row.key), from, from + window)
    if path then paths[row.key] = path end
  end
  return dir, paths
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
function M.match(repo_dir, references_path, paths)
  local takes = {}
  for key, path in pairs(paths) do
    takes[#takes + 1] = { id = tostring(key), path = path }
  end
  if #takes == 0 then return {} end

  local input_path = string.format("%s/reapertoire-match-%d.json", temp_dir(), os.time())
  local f = io.open(input_path, "w")
  if not f then return {} end
  f:write(json.encode({ takes = takes }))
  f:close()

  local out = run(string.format(
    "%q %q match --refs %q --input %q",
    python(repo_dir), repo_dir .. "/tools/recognise/recognise.py",
    references_path, input_path))
  os.remove(input_path)

  if not out or out == "" then return {} end
  local parsed = json.decode(out)
  if type(parsed) ~= "table" or type(parsed.results) ~= "table" then return {} end

  local results = {}
  for key, ranked in pairs(parsed.results) do
    results[tonumber(key) or key] = ranked
  end
  return results
end

-- Rebuilds the reference library from every named take already rendered.
-- Returns a short summary line, or nil and a reason.
function M.index(repo_dir, sessions_root, references_path)
  local out = run(string.format(
    "%q %q index --sessions-root %q --out %q",
    python(repo_dir), repo_dir .. "/tools/recognise/recognise.py",
    sessions_root, references_path))
  if not out or out == "" then return nil, "the recogniser produced no output" end
  local parsed = json.decode(out)
  if type(parsed) ~= "table" then return nil, "unexpected output: " .. out:sub(1, 120) end
  return parsed
end

return M
