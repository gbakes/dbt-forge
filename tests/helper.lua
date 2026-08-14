-- Minimal `vim` stub so specs run under bare luajit via busted.
-- Only the surface the plugin actually touches is provided; individual
-- specs override these fields directly when they need richer behaviour.
_G.vim = _G.vim or {}

vim.fn = vim.fn or {}
vim.log = vim.log or { levels = { ERROR = 1, WARN = 2, INFO = 3, DEBUG = 4, TRACE = 5 } }
vim.notify = vim.notify or function() end

vim.loop = vim.loop or {}
-- Real fs_stat, minus the fields we do not use. Specs that need a specific
-- stat result override this.
vim.loop.fs_stat = vim.loop.fs_stat or function(path)
  local handle = io.open(path, "r")
  if not handle then
    return nil
  end
  local size = handle:seek("end")
  handle:close()
  return { size = size, mtime = { sec = 0 } }
end

vim.json = vim.json or {}
vim.json.decode = vim.json.decode or function()
  error("vim.json.decode is not stubbed; specs should use the Lua fixture instead")
end

-- Inert defaults for the vim.fn surface reached via config.setup() ->
-- utils.get_project_config() (find_dbt_project_path / detect_python_env).
-- Each returns the "nothing found" value for its real vim.fn counterpart, so
-- auto-detection cleanly finds no project/env and setup() falls through to
-- whatever the caller passed in explicitly. Specs that need richer behaviour
-- assign these fields directly (plain assignment, not `or`), which always
-- wins over these defaults because this file runs once, first, as the
-- busted helper.

vim.fn.expand = vim.fn.expand or function()
  return ""
end

vim.fn.filereadable = vim.fn.filereadable or function()
  return 0
end

vim.fn.fnamemodify = vim.fn.fnamemodify or function(path, mods)
  if mods == ":h" then
    -- Empty/root paths have no parent left to walk up to; returning "/"
    -- gives find_dbt_project_path's loop a place to stop.
    if path == "" or path == "/" then
      return "/"
    end
    local head = path:match("^(.*)/[^/]+$")
    return (head ~= nil and head ~= "") and head or "/"
  end
  return path
end

vim.fn.finddir = vim.fn.finddir or function()
  return ""
end

vim.fn.findfile = vim.fn.findfile or function()
  return ""
end

vim.fn.isdirectory = vim.fn.isdirectory or function()
  return 0
end

vim.fn.readdir = vim.fn.readdir or function()
  return {}
end

local function deepcopy(v)
  if type(v) ~= "table" then
    return v
  end
  local out = {}
  for k, vv in pairs(v) do
    out[k] = deepcopy(vv)
  end
  return out
end

-- Check if a table is list-like (keys are exactly 1..n, empty is a list).
local function is_list(t)
  if type(t) ~= "table" then
    return false
  end
  local count = 0
  for k, _ in pairs(t) do
    if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then
      return false
    end
    count = count + 1
  end
  -- Empty table and consecutive 1..n both count as list-like
  for i = 1, count do
    if t[i] == nil then
      return false
    end
  end
  return true
end

-- Deep-copies on assignment. A shallow version would alias nested tables
-- from config.defaults into config.options, so the second setup() call in a
-- test run would see the first call's values.
-- Matches Neovim's semantics: recurse into map-like tables, replace list-like tables wholesale.
-- Matches Neovim's real vim.pesc: escape Lua pattern magic characters.
vim.pesc = vim.pesc or function(s)
  return (s:gsub("[%%%^%$%(%)%.%[%]%*%+%-%?]", "%%%1"))
end

vim.tbl_deep_extend = vim.tbl_deep_extend or function(_, ...)
  local out = {}
  local function merge(dst, src)
    for k, v in pairs(src) do
      -- Only recurse into map-like tables; replace list-like tables wholesale
      if type(v) == "table" and type(dst[k]) == "table" and not is_list(v) and not is_list(dst[k]) then
        merge(dst[k], v)
      else
        dst[k] = deepcopy(v)
      end
    end
  end
  for _, t in ipairs({ ... }) do
    merge(out, t)
  end
  return out
end
