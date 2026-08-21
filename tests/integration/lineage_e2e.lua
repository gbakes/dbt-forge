-- End-to-end check: fabricate a dbt project on disk, open a model, run
-- :DbtLineage, and assert what lands in the sidebar buffer.
--
-- Run via tests/integration/run.sh. Exits non-zero on the first failure.

local failures = {}

local function check(ok, message)
  if not ok then
    table.insert(failures, message)
  end
end

local function contains(haystack, needle)
  return haystack:find(needle, 1, true) ~= nil
end

-- The project on disk comes from the shared fixture; see project_fixture.lua.
package.path = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
  .. "/?.lua;" .. package.path
local root = require("project_fixture")()

require("dbt-forge").setup({
  dbt_project_path = root,
  python_env_manager = "none",
  lineage = { up_depth = 2, down_depth = 2, width = 48, follow = true },
})

vim.cmd("edit " .. root .. "/models/marts/fct_orders.sql")
local editing_win = vim.api.nvim_get_current_win()

vim.cmd("DbtLineage")

local view = require("dbt-forge.lineage_view")
check(view.is_open(), "sidebar did not open")

local sidebar_win = vim.api.nvim_get_current_win()
check(sidebar_win ~= editing_win, "focus stayed in the editing window")
check(
  vim.api.nvim_win_get_width(sidebar_win) == 48,
  "sidebar width is " .. vim.api.nvim_win_get_width(sidebar_win) .. ", expected 48"
)

local buf = vim.api.nvim_win_get_buf(sidebar_win)
local body = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")

check(contains(body, "◉"), "no root glyph in buffer")
check(contains(body, "●"), "no node glyph in buffer")
check(contains(body, "fct_orders"), "root model missing")
check(contains(body, "stg_orders"), "upstream model missing")
check(contains(body, "dim_customers"), "downstream model missing")
check(contains(body, "int_pivot"), "ephemeral model missing")
check(contains(body, "ephemeral"), "ephemeral materialization label missing")
check(contains(body, "jaffle.orders"), "source not named source_name.table_name")
check(not contains(body, "unique_order_id"), "test node leaked into the graph")

check(
  contains(vim.wo[sidebar_win].winbar, "fct_orders"),
  "winbar missing the model name"
)
check(contains(vim.wo[sidebar_win].winbar, "↑2 ↓2"), "winbar missing depths")

-- Ephemeral models must be italicised, and must still take their colour from
-- the colorscheme's Special. This resolves the highlight the way a UI does
-- (link = false), because a `link` in nvim_set_hl resolves to the target's
-- attributes alone -- an italic passed alongside it never reaches the screen.
local eph = vim.api.nvim_get_hl(0, { name = "DbtForgeLineageEphemeral", link = false })
local special = vim.api.nvim_get_hl(0, { name = "Special", link = false })
check(eph.italic == true, "ephemeral highlight is not italic: " .. vim.inspect(eph))
check(
  eph.fg == special.fg,
  "ephemeral highlight lost Special's colour: " .. vim.inspect(eph) .. " vs " .. vim.inspect(special)
)

-- A colorscheme change must re-derive it. A link would have tracked the new
-- colorscheme for free; a derived definition only does so if something hooks
-- ColorScheme, and a stale colour here would be a regression, not a nitpick.
vim.cmd("colorscheme habamax")
local eph_after = vim.api.nvim_get_hl(0, { name = "DbtForgeLineageEphemeral", link = false })
local special_after = vim.api.nvim_get_hl(0, { name = "Special", link = false })
check(eph_after.italic == true, "ephemeral lost italic after a colorscheme change")
check(
  eph_after.fg == special_after.fg,
  "ephemeral colour went stale after a colorscheme change: "
    .. vim.inspect(eph_after) .. " vs Special " .. vim.inspect(special_after)
)
check(special_after.fg ~= special.fg, "test is vacuous: habamax's Special matches the default's")

-- `-` narrows to one hop each way, which must drop the two-hop source.
vim.api.nvim_set_current_win(sidebar_win)
vim.api.nvim_feedkeys("-", "x", false)
local narrowed = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
check(not contains(narrowed, "jaffle.orders"), "- did not narrow the graph")

vim.api.nvim_feedkeys("+", "x", false)
local widened = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
check(contains(widened, "jaffle.orders"), "+ did not widen the graph")

-- <CR> on a node opens that model in the editing window.
local target_line
for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
  if contains(line, "dim_customers") then
    target_line = i
  end
end
check(target_line ~= nil, "could not find dim_customers row")

if target_line then
  vim.api.nvim_set_current_win(sidebar_win)
  vim.api.nvim_win_set_cursor(sidebar_win, { target_line, 0 })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  check(
    contains(vim.api.nvim_buf_get_name(0), "dim_customers.sql"),
    "<CR> opened " .. vim.api.nvim_buf_get_name(0) .. ", expected dim_customers.sql"
  )
  check(view.is_open(), "sidebar closed after <CR>")
end

-- Re-rooting on the node under the cursor.
vim.api.nvim_set_current_win(sidebar_win)
for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
  if contains(line, "stg_orders") then
    vim.api.nvim_win_set_cursor(sidebar_win, { i, 0 })
    break
  end
end
vim.api.nvim_feedkeys("r", "x", false)
check(
  contains(vim.wo[sidebar_win].winbar, "stg_orders"),
  "r did not re-root the graph"
)

-- The mtime cache: a second load of an unchanged manifest must return the
-- identical table, not a fresh projection.
local manifest_mod = require("dbt-forge.manifest")
local include = { "model", "source", "seed", "snapshot", "exposure" }
local first = manifest_mod.load(root, include)
local second = manifest_mod.load(root, include)
check(rawequal(first, second), "mtime cache returned a different table")

if #failures > 0 then
  io.stderr:write("FAIL (" .. #failures .. ")\n")
  for _, message in ipairs(failures) do
    io.stderr:write("  - " .. message .. "\n")
  end
  vim.cmd("cquit 1")
end

print("integration: all checks passed")
vim.cmd("qa!")
