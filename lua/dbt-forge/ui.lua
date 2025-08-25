local M = {}
local config = require("dbt-forge.config")

function M.run_in_split(cmd)
    vim.cmd("split")
    vim.cmd("resize " .. config.options.ui.split_size)
    vim.cmd("terminal " .. cmd)
    vim.cmd("startinsert")
end

function M.show_transpiled_sql(filename, incremental_sql, non_incremental_sql)
    local content = {}
    table.insert(content, "-- DBT MODEL: " .. filename)
    table.insert(content, "")
    table.insert(content, "-- =====================================")
    table.insert(content, "-- INCREMENTAL SQL")
    table.insert(content, "-- =====================================")
    table.insert(content, "")
    for line in incremental_sql:gmatch("[^\r\n]+") do
        table.insert(content, line)
    end
    table.insert(content, "")
    table.insert(content, "")
    table.insert(content, "-- =====================================")
    table.insert(content, "-- NON-INCREMENTAL SQL (FULL REFRESH)")
    table.insert(content, "-- =====================================")
    table.insert(content, "")
    if non_incremental_sql ~= "" and non_incremental_sql ~= incremental_sql then
        for line in non_incremental_sql:gmatch("[^\r\n]+") do
            table.insert(content, line)
        end
    else
        table.insert(content, "-- Same as incremental version")
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

return M

