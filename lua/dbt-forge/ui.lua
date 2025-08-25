local M = {}
local config = require("dbt-forge.config")

function M.run_in_split(cmd)
    vim.cmd("split")
    vim.cmd("resize " .. config.options.ui.split_size)
    vim.cmd("terminal " .. cmd)
    vim.cmd("startinsert")
end

function M.show_transpiled_sql(filename, incremental_sql, non_incremental_sql)
  local has_differences = non_incremental_sql ~= "" and non_incremental_sql ~= incremental_sql
  
  if has_differences then
    M.show_sql_comparison(filename, incremental_sql, non_incremental_sql)
  else
    M.show_single_sql(filename, incremental_sql, true)
  end
end

function M.show_single_sql(filename, sql_content, is_same_version)
  local content = {}
  table.insert(content, "-- DBT MODEL: " .. filename)
  table.insert(content, "")
  
  if is_same_version then
    table.insert(content, "-- ✓ Incremental and full-refresh SQL are identical")
    table.insert(content, "")
  end
  
  for line in sql_content:gmatch("[^\r\n]+") do
    table.insert(content, line)
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
  vim.api.nvim_buf_set_option(buf, "filetype", "sql")
  vim.api.nvim_buf_set_option(buf, "readonly", true)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)

  local width = math.floor(vim.o.columns * config.options.ui.float_width_ratio)
  local height = math.floor(vim.o.lines * config.options.ui.float_height_ratio)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local opts = {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    border = config.options.ui.float_border,
    title = " DBT Transpiled SQL: " .. filename .. " ",
    title_pos = "center",
  }

  local win = vim.api.nvim_open_win(buf, true, opts)
  vim.api.nvim_win_set_option(win, "wrap", false)
  vim.api.nvim_win_set_option(win, "cursorline", true)

  vim.api.nvim_buf_set_keymap(buf, "n", "q", "<cmd>close<cr>", { noremap = true, silent = true })
  vim.api.nvim_buf_set_keymap(buf, "n", "<ESC>", "<cmd>close<cr>", { noremap = true, silent = true })
end

function M.show_sql_comparison(filename, incremental_sql, non_incremental_sql)
  local incremental_lines = {}
  table.insert(incremental_lines, "-- INCREMENTAL SQL")
  table.insert(incremental_lines, "")
  for line in incremental_sql:gmatch("[^\r\n]+") do
    table.insert(incremental_lines, line)
  end

  local non_incremental_lines = {}
  table.insert(non_incremental_lines, "-- NON-INCREMENTAL SQL (FULL REFRESH)")
  table.insert(non_incremental_lines, "")
  for line in non_incremental_sql:gmatch("[^\r\n]+") do
    table.insert(non_incremental_lines, line)
  end

  local buf1 = vim.api.nvim_create_buf(false, true)
  local buf2 = vim.api.nvim_create_buf(false, true)
  
  vim.api.nvim_buf_set_lines(buf1, 0, -1, false, incremental_lines)
  vim.api.nvim_buf_set_lines(buf2, 0, -1, false, non_incremental_lines)
  
  for _, buf in ipairs({buf1, buf2}) do
    vim.api.nvim_buf_set_option(buf, "filetype", "sql")
    vim.api.nvim_buf_set_option(buf, "readonly", true)
    vim.api.nvim_buf_set_option(buf, "modifiable", false)
  end

  local total_width = math.floor(vim.o.columns * config.options.ui.float_width_ratio)
  local height = math.floor(vim.o.lines * config.options.ui.float_height_ratio)
  local width = math.floor(total_width / 2) - 1
  local row = math.floor((vim.o.lines - height) / 2)
  local col1 = math.floor((vim.o.columns - total_width) / 2)
  local col2 = col1 + width + 2

  local opts1 = {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col1,
    border = config.options.ui.float_border,
    title = " Incremental ",
    title_pos = "center",
  }

  local opts2 = {
    relative = "editor", 
    width = width,
    height = height,
    row = row,
    col = col2,
    border = config.options.ui.float_border,
    title = " Full Refresh ",
    title_pos = "center",
  }

  local win1 = vim.api.nvim_open_win(buf1, true, opts1)
  local win2 = vim.api.nvim_open_win(buf2, false, opts2)
  
  for _, win in ipairs({win1, win2}) do
    vim.api.nvim_win_set_option(win, "wrap", false)
    vim.api.nvim_win_set_option(win, "cursorline", true)
  end

  for _, buf in ipairs({buf1, buf2}) do
    vim.api.nvim_buf_set_keymap(buf, "n", "q", "<cmd>close<cr>", { noremap = true, silent = true })
    vim.api.nvim_buf_set_keymap(buf, "n", "<ESC>", "<cmd>close<cr>", { noremap = true, silent = true })
    vim.api.nvim_buf_set_keymap(buf, "n", "<Tab>", "<C-w>w", { noremap = true, silent = true })
  end
end

return M

