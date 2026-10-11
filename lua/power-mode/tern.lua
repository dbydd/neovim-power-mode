--- Tern bridge for the dbydd fork of neovim-power-mode.
---
--- Inside the Tern terminal the loud screen effects are Tern's own: its `cursor.trail` and
--- `cursor.pulse` (Settings › Appearance › Cursor). The Tern half of this fork escalates which
--- pair is playing with the combo level; this module is only the signal.
---
--- It writes one small JSON per working directory, `<dir>/<sha256(cwd)[1:16]>.json`, holding the
--- combo, its level and when it was last touched — the same rendezvous the `power-surge` Tern
--- plugin reads. Neovim cannot call Tern's settings API (only a Tern plugin VM can), so the file
--- is the whole interface: no shared clock, no races with Tern's own settings writes.
---
--- Outside Tern this module does nothing at all.
local M = {}

local uv = vim.uv or vim.loop

local state = {
  enabled = true,
  dir = "/tmp/power-surge",
  interval_ms = 120, -- how often the file is rewritten while typing
  made_dir = false,
  published = nil,
}

local in_tern = nil

local function is_tern()
  if in_tern == nil then
    in_tern = vim.env.TERM_PROGRAM == "tern"
  end
  return in_tern
end

--- Configure the bridge. `opts` is the plugin's `tern` table.
function M.setup(opts)
  opts = opts or {}
  state.enabled = opts.enabled ~= false
  state.dir = opts.dir or state.dir
  state.interval_ms = opts.interval_ms or state.interval_ms
end

--- Write the state for `level`/`combo`. `force` skips the throttle (level changes and the
--- final zero must always land).
function M.publish(level, combo, force)
  if not state.enabled or not is_tern() then
    return
  end
  local t = uv.now()
  if not force and t - (state.published or 0) < state.interval_ms then
    return
  end
  state.published = t
  if not state.made_dir then
    state.made_dir = true
    pcall(vim.fn.mkdir, state.dir, "p")
  end
  local cwd = vim.fn.getcwd()
  local payload = vim.json.encode({
    cwd = cwd,
    home = vim.env.HOME, -- Tern shows the home directory as `~`; it needs the prefix to match
    combo = combo or 0,
    level = level or 0,
    at = t,
  })
  pcall(vim.fn.writefile, { payload }, state.dir .. "/" .. vim.fn.sha256(cwd):sub(1, 16) .. ".json")
end

--- The combo died: say so, so the terminal's effects go back to the user's own.
function M.clear()
  M.publish(0, 0, true)
end

--- For tests.
function M._in_tern()
  return is_tern()
end

function M._dir()
  return state.dir
end

return M
