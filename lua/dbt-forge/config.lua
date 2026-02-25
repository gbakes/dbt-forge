local M = {}

M.defaults = {
  dbt_project_path = nil, -- Must be set by user
  python_env_manager = "pyenv", -- "pyenv", "conda", "venv", or "none"
  python_env_name = nil, -- Environment name
  keymaps = {
    run_model = "<leader>dr",
    transpile_model = "<leader>dt",
    test_model = "<leader>dT",
    goto_definition = "gd",
  },
  ui = {
    split_size = 15,
    float_border = "rounded",
    float_width_ratio = 0.8,
    float_height_ratio = 0.8,
  }
}

M.options = {}

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
  
  local utils = require("dbt-forge.utils")
  local project_config = utils.get_project_config()
  
  if not M.options.dbt_project_path and project_config.dbt_project_path then
    M.options.dbt_project_path = project_config.dbt_project_path
    vim.notify("dbt-forge.nvim: Auto-detected DBT project at " .. project_config.dbt_project_path, vim.log.levels.INFO)
  end
  
  if not M.options.python_env_name and project_config.python_env_name then
    M.options.python_env_manager = project_config.python_env_manager
    M.options.python_env_name = project_config.python_env_name
    vim.notify("dbt-forge.nvim: Auto-detected " .. project_config.python_env_manager .. " environment: " .. project_config.python_env_name, vim.log.levels.INFO)
  end
  
  if not M.options.dbt_project_path then
    vim.notify("dbt-forge.nvim: Could not find dbt_project.yml. Please set dbt_project_path in setup() or run from within a DBT project.", vim.log.levels.WARN)
  end
end

return M