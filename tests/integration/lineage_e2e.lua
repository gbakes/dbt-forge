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

-- Build a throwaway dbt project: dbt_project.yml, two model files, and a
-- manifest.json describing a diamond through an ephemeral model.
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/models/marts", "p")
vim.fn.mkdir(root .. "/models/staging", "p")
vim.fn.mkdir(root .. "/target", "p")

vim.fn.writefile({ "name: jaffle_shop", "version: '1.0'" }, root .. "/dbt_project.yml")
vim.fn.writefile({ "select 1 as order_id" }, root .. "/models/marts/fct_orders.sql")
vim.fn.writefile({ "select 1 as order_id" }, root .. "/models/staging/stg_orders.sql")
vim.fn.writefile({ "select 1 as customer_id" }, root .. "/models/marts/dim_customers.sql")

local manifest = {
  metadata = { project_name = "jaffle_shop" },
  nodes = {
    ["model.jaffle_shop.stg_orders"] = {
      name = "stg_orders", resource_type = "model", package_name = "jaffle_shop",
      original_file_path = "models/staging/stg_orders.sql",
      config = { materialized = "view" },
    },
    ["model.jaffle_shop.int_pivot"] = {
      name = "int_pivot", resource_type = "model", package_name = "jaffle_shop",
      original_file_path = "models/staging/int_pivot.sql",
      config = { materialized = "ephemeral" },
    },
    ["model.jaffle_shop.fct_orders"] = {
      name = "fct_orders", resource_type = "model", package_name = "jaffle_shop",
      original_file_path = "models/marts/fct_orders.sql",
      config = { materialized = "table" },
    },
    ["model.jaffle_shop.dim_customers"] = {
      name = "dim_customers", resource_type = "model", package_name = "jaffle_shop",
      original_file_path = "models/marts/dim_customers.sql",
      config = { materialized = "table" },
    },
    ["test.jaffle_shop.unique_order_id.abc"] = {
      name = "unique_order_id", resource_type = "test", package_name = "jaffle_shop",
      original_file_path = "models/marts/schema.yml", config = {},
    },
  },
  sources = {
    ["source.jaffle_shop.jaffle.orders"] = {
      name = "orders", source_name = "jaffle", resource_type = "source",
      package_name = "jaffle_shop", original_file_path = "models/staging/sources.yml",
    },
  },
  exposures = {},
  parent_map = {
    ["source.jaffle_shop.jaffle.orders"] = {},
    ["model.jaffle_shop.stg_orders"] = { "source.jaffle_shop.jaffle.orders" },
    ["model.jaffle_shop.int_pivot"] = { "model.jaffle_shop.stg_orders" },
    ["model.jaffle_shop.fct_orders"] = {
      "model.jaffle_shop.stg_orders", "model.jaffle_shop.int_pivot",
    },
    ["model.jaffle_shop.dim_customers"] = { "model.jaffle_shop.fct_orders" },
    ["test.jaffle_shop.unique_order_id.abc"] = { "model.jaffle_shop.fct_orders" },
  },
  child_map = {
    ["source.jaffle_shop.jaffle.orders"] = { "model.jaffle_shop.stg_orders" },
    ["model.jaffle_shop.stg_orders"] = {
      "model.jaffle_shop.fct_orders", "model.jaffle_shop.int_pivot",
    },
    ["model.jaffle_shop.int_pivot"] = { "model.jaffle_shop.fct_orders" },
    ["model.jaffle_shop.fct_orders"] = {
      "model.jaffle_shop.dim_customers", "test.jaffle_shop.unique_order_id.abc",
    },
    ["model.jaffle_shop.dim_customers"] = {},
  },
}

vim.fn.writefile({ vim.json.encode(manifest) }, root .. "/target/manifest.json")

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
