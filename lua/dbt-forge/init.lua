local M = {}

local config = require("dbt-forge.config")
local utils = require("dbt-forge.utils")
local ui = require("dbt-forge.ui")

function M.setup(opts)
  config.setup(opts)
  
  if config.options.keymaps.run_model then
    vim.keymap.set("n", config.options.keymaps.run_model, M.run_model, {
      desc = "Run dbt model from current file",
      noremap = true,
      silent = true,
    })
  end

  if config.options.keymaps.transpile_model then
    vim.keymap.set("n", config.options.keymaps.transpile_model, M.transpile_model, {
      desc = "Transpile dbt model and show SQL in floating window",
      noremap = true,
      silent = true,
    })
  end

  if config.options.keymaps.test_model then
    vim.keymap.set("n", config.options.keymaps.test_model, M.test_model, {
      desc = "Run tests for current dbt model",
      noremap = true,
      silent = true,
    })
  end
end

function M.run_model()
  local filename = vim.fn.expand("%:t:r")

  if not utils.is_sql_file() then
    vim.notify("Not a SQL file", vim.log.levels.WARN)
    return
  end

  local cmd = utils.build_dbt_command(string.format(
    'echo "Running dbt model: %s" && dbt run --select %s && echo "\\n--- Sample Results (first 20 rows) ---" && dbt show --select %s --limit 20',
    filename,
    filename,
    filename
  ))

  ui.run_in_split(cmd)
end

function M.transpile_model()
  local filename = vim.fn.expand("%:t:r")

  if not utils.is_sql_file() then
    vim.notify("Not a SQL file", vim.log.levels.WARN)
    return
  end

  local loading = require("dbt-forge.loading")
  
  -- Show loading screen
  loading.show_loading("DBT Transpiling: " .. filename, "🔮 Consulting the data crystal...")

  local compile_cmd = utils.build_dbt_command(string.format('dbt compile --select %s', filename))
  local compile_full_refresh_cmd = utils.build_dbt_command(string.format('dbt compile --select %s --full-refresh', filename))

  -- Run first compilation with loading feedback
  local job_id = utils.run_command_with_callback(compile_cmd, function(output)
    loading.append_output(output)
  end)

  -- Wait for first command to complete, then run second
  vim.fn.jobwait({job_id}, 30000) -- 30 second timeout

  local compiled_file_path = utils.find_compiled_file(filename)
  if not compiled_file_path then
    loading.hide_loading()
    vim.notify("Could not find compiled SQL file", vim.log.levels.ERROR)
    return
  end

  local incremental_sql = utils.read_file(compiled_file_path)
  if not incremental_sql then
    loading.hide_loading()
    vim.notify("Could not read compiled SQL file", vim.log.levels.ERROR)
    return
  end

  -- Run second compilation for full refresh
  loading.append_output("\n📝 Compiling full-refresh version...")
  local job_id2 = utils.run_command_with_callback(compile_full_refresh_cmd, function(output)
    loading.append_output(output)
  end)

  vim.fn.jobwait({job_id2}, 30000) -- 30 second timeout

  local non_incremental_sql = utils.read_file(compiled_file_path) or ""

  -- Hide loading and show results
  loading.hide_loading()
  ui.show_transpiled_sql(filename, incremental_sql, non_incremental_sql)
end

function M.test_model()
  local filename = vim.fn.expand("%:t:r")

  if not utils.is_sql_file() then
    vim.notify("Not a SQL file", vim.log.levels.WARN)
    return
  end

  local cmd = utils.build_dbt_command(string.format(
    'echo "Running tests for dbt model: %s" && dbt test --select %s',
    filename,
    filename
  ))

  ui.run_in_split(cmd)
end

return M