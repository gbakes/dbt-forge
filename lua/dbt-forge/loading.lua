local M = {}
local config = require("dbt-forge.config")

M.funny_messages = {
    "Diving the stakeholder's requirements",
    "Seancing the project documentation",
    "Reading the stakeholder requirements tea leaves",
    "Channeling the spirits of JIRA tickets past",
    "Reading the aura of your codebase",
    "Divining the location of missing data",
    "Casting SQspells",
    "Summoning models from the astral plane",
    "Using clairvoyance to deliver it yesterday",
    "Astral projecting the deadline to next week",
    "Gazing into the void... the void gazes back with more requirements",
}

M.current_loading = nil

function M.show_loading(title, initial_message)
    if M.current_loading then
        M.hide_loading()
    end

    title = title or "DBT Forge"
    initial_message = initial_message or M.funny_messages[math.random(#M.funny_messages)]

    -- Force redraw to ensure loading screen appears
    vim.cmd("redraw")

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
    vim.api.nvim_buf_set_option(buf, "swapfile", false)

    local width = 60
    local height = 15
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    local border_chars = config.options.ui.float_border == "rounded"
            and { "╭", "─", "╮", "│", "╯", "─", "╰", "│" }
        or { "┌", "─", "┐", "│", "┘", "─", "└", "│" }

    local opts = {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        border = border_chars,
        title = " " .. title .. " ",
        title_pos = "center",
        style = "minimal",
    }

    local win = vim.api.nvim_open_win(buf, false, opts)
    vim.api.nvim_win_set_option(win, "wrap", true)
    vim.api.nvim_win_set_option(win, "cursorline", false)

    -- Initialize content
    local content = {
        "",
        "    ⏳ Working...",
        "",
        "    " .. initial_message,
        "",
        "    Output:",
        "    " .. string.rep("─", 50),
        ""
    }

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)

    -- Store loading state
    M.current_loading = {
        buf = buf,
        win = win,
        message_line = 3, -- Line where the rotating message is (0-indexed)
        output_start_line = 7, -- Line where output begins (0-indexed, after the separator)
        message_timer = nil,
        current_message_index = 1,
    }

    -- Start rotating funny messages
    M.start_message_rotation()

    return M.current_loading
end

function M.start_message_rotation()
    if not M.current_loading then
        return
    end

    local function update_message()
        if not M.current_loading or not vim.api.nvim_buf_is_valid(M.current_loading.buf) then
            return
        end

        M.current_loading.current_message_index = M.current_loading.current_message_index + 1
        if M.current_loading.current_message_index > #M.funny_messages then
            M.current_loading.current_message_index = 1
        end

        local new_message = M.funny_messages[M.current_loading.current_message_index]
        
        -- Update the buffer line (hardcoded to line 3 for now)
        local success, err = pcall(vim.api.nvim_buf_set_lines, 
            M.current_loading.buf, 3, 4, false, { "    " .. new_message })
        
        if success then
            vim.schedule(function() vim.cmd("redraw") end)
        end

        -- Schedule next update
        if M.current_loading then
            M.current_loading.message_timer = vim.defer_fn(update_message, 2000)
        end
    end

    -- Start the rotation
    M.current_loading.message_timer = vim.defer_fn(update_message, 2000)
end

function M.append_output(text)
    if not M.current_loading or not vim.api.nvim_buf_is_valid(M.current_loading.buf) then
        return
    end

    -- Get current lines
    local lines = vim.api.nvim_buf_get_lines(M.current_loading.buf, 0, -1, false)

    -- Split text into lines and add them
    for line in text:gmatch("[^\r\n]+") do
        if line:match("%S") then -- Only add non-empty lines
            table.insert(lines, "    " .. line)
        end
    end

    -- Limit to reasonable number of lines (keep last 20 lines of output)
    local header_lines = M.current_loading.output_start_line
    if #lines > header_lines + 20 then
        local new_lines = {}
        -- Keep header
        for i = 1, header_lines do
            table.insert(new_lines, lines[i])
        end
        -- Keep last 20 output lines
        for i = #lines - 19, #lines do
            table.insert(new_lines, lines[i])
        end
        lines = new_lines
    end

    vim.api.nvim_buf_set_lines(M.current_loading.buf, 0, -1, false, lines)

    -- Auto-scroll to bottom
    if vim.api.nvim_win_is_valid(M.current_loading.win) then
        vim.api.nvim_win_set_cursor(M.current_loading.win, { #lines, 0 })
    end
end

function M.hide_loading()
    if not M.current_loading then
        return
    end

    -- Stop message rotation timer (defer_fn based)
    if M.current_loading.message_timer then
        -- The timer will naturally stop when M.current_loading becomes nil
        M.current_loading.message_timer = nil
    end

    -- Close window and buffer
    if vim.api.nvim_win_is_valid(M.current_loading.win) then
        vim.api.nvim_win_close(M.current_loading.win, true)
    end

    if vim.api.nvim_buf_is_valid(M.current_loading.buf) then
        vim.api.nvim_buf_delete(M.current_loading.buf, { force = true })
    end

    M.current_loading = nil
end

return M
