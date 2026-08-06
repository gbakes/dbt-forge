-- Minimal `vim` stub so specs run under bare luajit via busted.
-- Only the surface the plugin actually touches is provided; individual
-- specs override these fields directly when they need richer behaviour.
_G.vim = _G.vim or {}

vim.fn = vim.fn or {}
vim.log = vim.log or { levels = { ERROR = 1, WARN = 2, INFO = 3, DEBUG = 4, TRACE = 5 } }
vim.notify = vim.notify or function() end

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

-- Deep-copies on assignment. A shallow version would alias nested tables
-- from config.defaults into config.options, so the second setup() call in a
-- test run would see the first call's values.
vim.tbl_deep_extend = vim.tbl_deep_extend or function(_, ...)
  local out = {}
  local function merge(dst, src)
    for k, v in pairs(src) do
      if type(v) == "table" and type(dst[k]) == "table" then
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
