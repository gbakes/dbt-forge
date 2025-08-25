local M = {}

M.defaults = {
  dbt_project_path = nil, -- Must be set by user
  python_env_manager = "pyenv", -- "pyenv", "conda", "venv", or "none"
  python_env_name = nil, -- Environment name
  keymaps = {
    run_model = "<leader>dr",
    transpile_model = "<leader>dt",
    test_model = "<leader>dT",
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
  
  if not M.options.dbt_project_path then
    vim.notify("dbt-forge.nvim: dbt_project_path is required in setup()", vim.log.levels.ERROR)
  end
end

return M