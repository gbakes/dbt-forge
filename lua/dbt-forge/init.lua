local M = {}

local config = require("dbt-forge.config")
local utils = require("dbt-forge.utils")
local ui = require("dbt-forge.ui")
local goto_def = require("dbt-forge.goto")

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

  if config.options.keymaps.lineage then
    vim.keymap.set("n", config.options.keymaps.lineage, M.show_lineage, {
      desc = "Show dbt model lineage",
      noremap = true,
      silent = true,
    })
  end

  if config.options.keymaps.goto_definition then
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "sql",
      callback = function(args)
        vim.keymap.set("n", config.options.keymaps.goto_definition, goto_def.goto_definition, {
          buffer = args.buf,
          desc = "Go to dbt model/source/macro definition",
          noremap = true,
          silent = true,
        })
      end,
    })
  end

  if config.options.lineage.follow then
    -- `clear = true` guards against double-registration: a second setup()
    -- call would otherwise stack a second autocmd, and since this one calls
    -- refocus() (unlike the FileType autocmd above, which is idempotent),
    -- that means a redundant manifest load and rerender on every buffer
    -- switch rather than just tidiness.
    local augroup = vim.api.nvim_create_augroup("DbtForgeLineageFollow", { clear = true })
    vim.api.nvim_create_autocmd("BufEnter", {
      group = augroup,
      pattern = "*.sql",
      callback = M._follow_current_buffer,
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
  loading.show_loading("DBT Transpiling: " .. filename)

  -- Use vim.defer_fn to ensure loading screen shows before starting work
  vim.defer_fn(function()
    local compile_cmd = utils.build_dbt_command(string.format('dbt compile --select %s', filename))
    local compile_full_refresh_cmd = utils.build_dbt_command(string.format('dbt compile --select %s --full-refresh', filename))

    -- Run first compilation asynchronously
    local job1 = vim.fn.jobstart(compile_cmd, {
      on_exit = function(_, exit_code)
        if exit_code ~= 0 then
          loading.hide_loading()
          vim.notify("Failed to compile dbt model", vim.log.levels.ERROR)
          return
        end

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

        -- Run second compilation for full refresh asynchronously
        local job2 = vim.fn.jobstart(compile_full_refresh_cmd, {
          on_exit = function(_, exit_code2)
            local non_incremental_sql = ""
            
            if exit_code2 == 0 then
              non_incremental_sql = utils.read_file(compiled_file_path) or ""
            end

            -- Small delay to see the loading screen, then hide and show results
            vim.defer_fn(function()
              loading.hide_loading()
              ui.show_transpiled_sql(filename, incremental_sql, non_incremental_sql)
            end, 1000) -- 1 second delay to see messages
          end
        })
      end
    })
  end, 100) -- Small delay to ensure loading screen renders
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

function M.show_lineage()
  local utils_mod = require("dbt-forge.utils")
  if not utils_mod.is_sql_file() then
    vim.notify("Not a SQL file", vim.log.levels.WARN)
    return
  end

  local manifest = require("dbt-forge.manifest")
  local graph, err = manifest.load(
    config.options.dbt_project_path,
    config.options.lineage.include
  )
  if not graph then
    vim.notify("dbt-forge: " .. err, vim.log.levels.ERROR)
    return
  end

  local name = vim.fn.expand("%:t:r")
  local rel_path = utils_mod.rel_path(config.options.dbt_project_path, vim.fn.expand("%:p"))
  -- `rel_path` is nil when the buffer lives outside the project entirely;
  -- short-circuit straight to the same "not in manifest" warning rather
  -- than calling resolve with a nil path.
  local node_id = rel_path and manifest.resolve(graph, name, rel_path)
  if not node_id then
    vim.notify(
      string.format("dbt-forge: %s not in manifest — run dbt parse", name),
      vim.log.levels.WARN
    )
    return
  end

  require("dbt-forge.lineage_view").open(node_id)
end

M.goto_definition = goto_def.goto_definition

-- Re-roots the already-open lineage sidebar on whatever model buffer the
-- user just switched to. Never interrupts: a closed sidebar, a missing/
-- unreadable manifest, a buffer outside the project, or a buffer that is
-- not a known model are all silently ignored — following should only
-- track, never notify or error.
function M._follow_current_buffer()
  local view = require("dbt-forge.lineage_view")
  -- Checked first, unconditionally: a keep-focus peek (`o` in the sidebar)
  -- sets this immediately before its own `:edit`, so the BufEnter that
  -- `:edit` fires synchronously must not re-root the sidebar onto the
  -- peeked node — that would defeat the entire point of keeping focus.
  -- Consuming it here (read-and-clear) even when the sidebar turns out to
  -- be closed keeps it from leaking into a later, unrelated BufEnter.
  if view.consume_follow_suppression() then
    return
  end
  if not view.is_open() then
    return
  end

  local manifest = require("dbt-forge.manifest")
  local graph = manifest.load(
    config.options.dbt_project_path,
    config.options.lineage.include
  )
  if not graph then
    return
  end

  local rel_path = utils.rel_path(config.options.dbt_project_path, vim.fn.expand("%:p"))
  if not rel_path then
    return
  end

  local node_id = manifest.resolve(graph, vim.fn.expand("%:t:r"), rel_path)
  if node_id then
    view.refocus(node_id)
  end
end

return M