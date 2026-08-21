-- End-to-end check for the floating presentation: that the sidebar really is a
-- float, that width_ratio = 1.0 means the full editor width, that rows are laid
-- out to what the graph needs rather than stranded against the far edge, and
-- that <CR> dismisses the float while `o` leaves it up.
--
-- Run via tests/integration/run.sh. Exits non-zero on the first failure.

package.path = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
  .. "/?.lua;" .. package.path

local failures = {}

local function check(ok, message)
  if not ok then
    table.insert(failures, message)
  end
end

local function longest_row(buf)
  local longest = 0
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    longest = math.max(longest, vim.fn.strchars(line))
  end
  return longest
end

local root = require("project_fixture")()

require("dbt-forge").setup({
  dbt_project_path = root,
  python_env_manager = "none",
  lineage = {
    presentation = "float",
    float = { width_ratio = 1.0, height_ratio = 0.8 },
    up_depth = 2,
    down_depth = 2,
    follow = true,
  },
})

vim.cmd("edit " .. root .. "/models/marts/fct_orders.sql")
vim.cmd("DbtLineage")

local view = require("dbt-forge.lineage_view")
check(view.is_open(), "float did not open")

local win = vim.api.nvim_get_current_win()
local buf = vim.api.nvim_win_get_buf(win)

-- A split reports relative = "", so this is what separates the two.
local relative = vim.api.nvim_win_get_config(win).relative
check(relative ~= nil and relative ~= "", "window is not floating: relative=" .. tostring(relative))

-- width_ratio = 1.0 means the full editor width. nvim_open_win's width excludes
-- the border, so a bordered full-width float is exactly two columns narrower --
-- if that subtraction were missing the float would overflow the editor.
local width = vim.api.nvim_win_get_width(win)
check(
  width == vim.o.columns - 2,
  ("float width is %d, expected %d (columns %d less the border)"):format(width, vim.o.columns - 2, vim.o.columns)
)

-- Rows lay out to the graph's own width, not the window's. Laying out to the
-- window is what pins every materialization tag against the far edge.
local longest = longest_row(buf)
check(longest < width, ("rows laid out to the window (%d) rather than the graph (%d)"):format(width, longest))
check(longest >= 20, "rows look implausibly short at " .. longest .. " -- is anything rendering?")

-- Winbar is window-local here, which is the only form a float honours.
local winbar = vim.wo[win].winbar
check(
  winbar ~= nil and winbar:find("fct_orders", 1, true) ~= nil,
  "winbar missing from the float: " .. tostring(winbar)
)

-- `o` peeks without dismissing the float.
local target
for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
  if line:find("dim_customers", 1, true) then
    target = i
  end
end
check(target ~= nil, "could not find the dim_customers row")

if target then
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { target, 0 })
  vim.api.nvim_feedkeys("o", "x", false)
  check(view.is_open(), "`o` dismissed the float; it should keep it up")
  check(vim.api.nvim_get_current_win() == win, "`o` did not keep focus in the float")
  -- Focus stayed in the float, so buffer 0 is the float's own. The opened
  -- model is in the other window, and that is what has to be asserted --
  -- checking buffer 0 here would pass no matter what `o` did.
  local behind
  for _, other in ipairs(vim.api.nvim_list_wins()) do
    if other ~= win then
      behind = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(other))
    end
  end
  check(
    behind ~= nil and behind:find("dim_customers.sql", 1, true) ~= nil,
    "`o` did not open the model behind the float, found: " .. tostring(behind)
  )
end

-- <CR> dismisses the float, because a buffer cannot be read underneath one.
-- Guarded: if the float has already gone the checks above have said so, and
-- driving a dead window from here would crash and bury that diagnostic.
if view.is_open() then
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:find("stg_orders", 1, true) then
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { i, 0 })
      break
    end
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  check(not view.is_open(), "<CR> left the float open on top of the file it just opened")
  check(
    vim.api.nvim_buf_get_name(0):find("stg_orders.sql", 1, true) ~= nil,
    "<CR> opened " .. vim.api.nvim_buf_get_name(0) .. ", expected stg_orders.sql"
  )
end

-- The ratio describes the whole footprint, border included. At 1.0 Neovim
-- clamps an over-wide float back inside the editor, which hides whether the
-- border was accounted for at all; at 0.5 the two columns are observable.
require("dbt-forge").setup({
  dbt_project_path = root,
  python_env_manager = "none",
  lineage = {
    presentation = "float",
    float = { width_ratio = 0.5, height_ratio = 0.5 },
    up_depth = 2,
    down_depth = 2,
    follow = true,
  },
})
vim.cmd("edit " .. root .. "/models/marts/fct_orders.sql")
vim.cmd("DbtLineage")
local half = vim.api.nvim_get_current_win()
local half_width = vim.api.nvim_win_get_width(half)
local expected_half = math.floor(vim.o.columns * 0.5) - 2
check(
  half_width == expected_half,
  ("half-width float is %d, expected %d (half of %d columns, less the border)")
    :format(half_width, expected_half, vim.o.columns)
)

if #failures > 0 then
  io.stderr:write("FAIL (" .. #failures .. ")\n")
  for _, message in ipairs(failures) do
    io.stderr:write("  - " .. message .. "\n")
  end
  vim.cmd("cquit 1")
end

print("integration (float): all checks passed")
vim.cmd("qa!")
