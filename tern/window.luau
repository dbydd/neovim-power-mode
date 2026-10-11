-- power-mode + Tern: the Tern half of the dbydd fork of neovim-power-mode.
--
-- One job: while a combo is live in the Neovim pane, turn Tern's own cursor effects up, and
-- put them back the way the user had them when the combo dies.
--
-- The screen effect is Tern's, not ours: `cursor.trail` (what the cursor leaves when it moves),
-- `cursor.pulse` (what a shape change sets off), `cursor.glide` (how far it flies to its next
-- place) and `cursor.shape` (which also fires the pulse again, since the shape changed). Nothing
-- is drawn, styled or titled here — the combo only picks which of Tern's effects is playing, and
-- at what volume. Rendering knobs (multisampling, frames queued) are left alone: they change
-- nothing a person can see.
--
-- Input comes from the Neovim half, which writes one small JSON per working directory
-- (`/tmp/power-surge/<sha>.json`): the combo, its level, and when it was last touched. This
-- half polls the file for the focused pane's directory and reacts to the level.
local STATE_DIR = "/tmp/power-surge"

--- What each combo level plays, climbing one notch per level: the terminal's cursor starts
--- leaving a comet on the first keystroke of a combo and ends on sparks with a box boom. The
--- last row is the ceiling, so a longer combo holds the loudest pair rather than running off
--- the end of either enum.
local LADDER = {
  [1] = { trail = "comet", pulse = "ripple", glide = 60, shape = nil },
  [2] = { trail = "comet", pulse = "box_ripple", glide = 90, shape = nil },
  [3] = { trail = "blaze", pulse = "box_ripple", glide = 120, shape = "soft" },
  [4] = { trail = "blaze", pulse = "sonic_boom", glide = 150, shape = "soft" },
  [5] = { trail = "sparks", pulse = "sonic_boom", glide = 190, shape = "bar" },
  [6] = { trail = "sparks", pulse = "box_boom", glide = 240, shape = "bar" },
}

--- macOS resolves /tmp through /private/tmp, and a pane's cwd may carry either spelling.
local function without_private(path)
  if path:sub(1, 9) == "/private/" then
    return path:sub(9)
  end
  return path
end

--- Tern shows the home directory as `~`, so compare a state file's absolute cwd in the same
--- form the tab uses.
local function display(path, home)
  if path == nil or path == "" then
    return nil
  end
  path = path:gsub("/+$", "")
  if home and home ~= "" and path:sub(1, #home) == home then
    local tail = path:sub(#home + 1)
    if tail == "" then
      return "~"
    end
    if tail:sub(1, 1) == "/" then
      return "~" .. tail
    end
  end
  return path
end

--- Where there is no room, Tern abbreviates every directory but the last to its first letter:
--- `/private/tmp` is shown as `/p/tmp`. A tab's cwd arrives either way, so both must match.
local function abbrev(path)
  local parts = {}
  for part in string.gmatch(path, "[^/]+") do
    parts[#parts + 1] = part
  end
  if #parts <= 1 then
    return path
  end
  local out = {}
  for i = 1, #parts - 1 do
    out[i] = string.sub(parts[i], 1, 1)
  end
  out[#parts] = parts[#parts]
  return "/" .. table.concat(out, "/")
end

--- Whether a state file belongs to `cwd`, in any of the spellings Tern may hand over.
local function matches(file, cwd)
  if file == nil or cwd == nil or cwd == "" then
    return false
  end
  local raw = file.cwd
  if raw == nil or raw == "" then
    return false
  end
  raw = raw:gsub("/+$", "")
  cwd = cwd:gsub("/+$", "")
  if raw == cwd or without_private(raw) == without_private(cwd) then
    return true
  end
  local shown = display(raw, file.home)
  for _, form in ipairs({ shown, abbrev(shown) }) do
    if form == cwd or without_private(form) == without_private(cwd) then
      return true
    end
  end
  return false
end

--- The state file for `cwd`, decoded, or nil.
local function state_for(cwd)
  if cwd == nil or cwd == "" or not tern.fs.exists(STATE_DIR) then
    return nil
  end
  for _, name in ipairs(tern.fs.list(STATE_DIR)) do
    if string.sub(name, -5) == ".json" then
      local ok, body = pcall(tern.fs.read, STATE_DIR .. "/" .. name, 4096)
      if ok and body then
        local decoded = tern.json.decode(body)
        if decoded and matches(decoded, cwd) then
          return decoded
        end
      end
    end
  end
  return nil
end

--- The focused tab's directory: it is the focused pane's cwd, and Tern reports it on the tab
--- (a pane's own `cwd` is the shell's, which is what we want, but only the tab is guaranteed).
local function focused_cwd(cx)
  local focus = cx.session:focused()
  for _, tab in ipairs(cx.session:tabs()) do
    if tab.pane == focus and tab.cwd and tab.cwd ~= "" then
      return tab.cwd
    end
  end
  return nil
end

-- The knob set this half owns, remembered in the plugin's key-value store: a crash mid-combo
-- must not leave the terminal louder than the user left it. `shape` is nil while the user keeps
-- each place's own shape.
local BASE_KEY = "base_cursor"
local KEYS = { "trail", "pulse", "glide", "shape" }
-- 2 added glide and shape. A store from 1 knows only the first two, and cannot say what the
-- user's shape was: `soft` and `bar` are this half's own values, so either one there is ours
-- and the baseline gets the place's own shape back.
local BASE_VERSION = 2
local OUR_SHAPES = { soft = true, bar = true }

--- Whether two knob sets agree on every key.
local function same(a, b)
  if a == nil or b == nil then
    return false
  end
  for _, key in ipairs(KEYS) do
    if a[key] ~= b[key] then
      return false
    end
  end
  return true
end

local function current_cursor(cx)
  local ok, value = pcall(cx.settings.get, cx.settings, "cursor")
  if not ok or type(value) ~= "table" then
    return nil
  end
  local out = {}
  for _, key in ipairs(KEYS) do
    out[key] = value[key]
  end
  return out
end

--- Bring a store written by an older release up to date. The trail and the pulse carry over;
--- the glide falls back to the live value (that release never touched it); the shape falls back
--- only if the live one is not ours.
local function upgrade(stored, live)
  local out = { v = BASE_VERSION }
  for _, key in ipairs(KEYS) do
    out[key] = stored[key]
  end
  out.glide = stored.glide
  if out.glide == nil then
    out.glide = live.glide
  end
  local shape = stored.shape
  if shape == nil then
    shape = live.shape
  end
  -- `A and nil or B` is B in Lua whatever A is, so this branch stays explicit.
  if OUR_SHAPES[shape] then
    shape = nil
  end
  out.shape = shape
  return out
end

--- The user's baseline: the store's, once it has one, else the settings as they stand. A stored
--- baseline that differs from the live settings is a boost left behind by a crash, so it wins
--- and is put back.
local function baseline(cx, level)
  local live = current_cursor(cx)
  if live == nil then
    return nil
  end
  local stored = tern.kv.get(BASE_KEY)
  if type(stored) ~= "table" then
    -- Nothing stored yet. Only capture while no combo is running, or a reload during one would
    -- record the boosted values as the user's own.
    if level == 0 then
      local fresh = { v = BASE_VERSION }
      for _, key in ipairs(KEYS) do
        fresh[key] = live[key]
      end
      tern.kv.set(BASE_KEY, fresh)
    end
    return live
  end
  local want = stored.v == BASE_VERSION and stored or upgrade(stored, live)
  if not same(want, live) then
    tern.log.warn("restoring cursor effects left boosted: " .. tern.json.encode(want))
  end
  tern.kv.set(BASE_KEY, want)
  return want
end

local base = nil
local applied = nil -- the set in effect, so a change costs one write per step

local function apply(cx, wanted)
  if wanted == nil or same(applied, wanted) then
    return
  end
  applied = {}
  for _, key in ipairs(KEYS) do
    applied[key] = wanted[key]
    pcall(cx.settings.set, cx.settings, "cursor." .. key, wanted[key])
  end
end

local function level_pair(level)
  return LADDER[math.min(math.max(level, 1), 6)]
end

--- Reads the focused directory's state and sets the effects for its level.
--- The baseline is read once, from the first context that has settings; the timer's `cx` is
--- the one that arrives first when the window is already up (a reload).
local function ensure_base(cx, level)
  if base == nil and cx and cx.settings then
    base = baseline(cx, level)
    applied = nil
    apply(cx, base)
  end
end

local function look(cx)
  local cwd = focused_cwd(cx)
  local s = state_for(cwd)
  local level = s and tonumber(s.level) or 0
  ensure_base(cx, level)
  if level > 0 then
    local pair = level_pair(level)
    if pair == nil then
      apply(cx, base)
      return
    end
    apply(cx, {
      trail = pair.trail,
      pulse = pair.pulse,
      glide = pair.glide,
      shape = pair.shape,
    })
    return
  end
  apply(cx, base)
end

-- Polling: a state file is the only signal, so the effects come back to the user's own a beat
-- after the last keystroke. One small `read` per tick.
local POLL_MS = 400

local function tick(cx)
  look(cx)
  tern.timer(POLL_MS, tick)
end

tern.on("window_start", function(cx)
  ensure_base(cx)
  tern.timer(POLL_MS, tick)
end)

-- Armed when this module runs too: on a reload the window is already up, so `window_start` has
-- come and gone, and this is what starts the poll again.
tern.timer(POLL_MS, tick)

--- `focus` carries the event first and its `cx` second, unlike `window_start`.
tern.on("focus", function(_, cx)
  look(cx)
end)

--- Commands: the easter egg and the toggle, aimed at the focused pane running Neovim.
---
--- `pane.program` reports the shell, never the editor inside it, so a pane counts as
--- Neovim's when the Neovim half has published a state file for its directory.
local function focused_nvim(cx)
  local focused = cx.session:focused()
  if focused == nil then
    return nil
  end
  for _, pane in ipairs(cx.session:panes()) do
    if pane.pane == focused and state_for(pane.cwd) then
      return pane.pane
    end
  end
  return nil
end

local function run_in_nvim(cx, lua)
  local pane = focused_nvim(cx)
  if pane == nil then
    cx:toast("info", "Power Mode rides in Neovim", "Open a file with nvim, then try again")
    return false
  end
  cx:run(pane, ':lua require("power-mode").' .. lua .. "\r")
  return true
end

tern.command({
  id = "toggle",
  title = "Power Mode: Toggle",
  icon = "zap",
  group = "Power Mode",
  keys = { "ctrl+alt+shift+p" },
  available = function(cx)
    return focused_nvim(cx) ~= nil
  end,
  run = function(cx)
    run_in_nvim(cx, "toggle()")
  end,
})
