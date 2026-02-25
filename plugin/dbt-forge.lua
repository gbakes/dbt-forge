if vim.g.loaded_dbt_forge then
  return
end

vim.g.loaded_dbt_forge = 1

vim.api.nvim_create_user_command("DbtRun", function()
  require("dbt-forge").run_model()
end, {
  desc = "Run the current DBT model",
})

vim.api.nvim_create_user_command("DbtTranspile", function()
  require("dbt-forge").transpile_model()
end, {
  desc = "Transpile and show compiled SQL for current DBT model",
})

vim.api.nvim_create_user_command("DbtTest", function()
  require("dbt-forge").test_model()
end, {
  desc = "Run tests for the current DBT model",
})

vim.api.nvim_create_user_command("DbtGotoDef", function()
  require("dbt-forge").goto_definition()
end, {
  desc = "Go to definition of dbt ref/source/macro under cursor",
})