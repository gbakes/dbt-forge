local M = {}

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

function M.show_loading(title)
    -- Clean up any existing loading screen
    if M.current_loading then
        M.hide_loading()
    end

    title = title or "DBT Forge"
    
    -- Create buffer
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
    vim.api.nvim_buf_set_option(buf, "swapfile", false)
    vim.api.nvim_buf_set_option(buf, "modifiable", false)

    -- Create window
    local width = 50
    local height = 8
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    local opts = {
        relative = "editor",
        width = width,
        height = height, 
        row = row,
        col = col,
        border = "rounded",
        title = " " .. title .. " ",
        title_pos = "center",
        style = "minimal"
    }

    local win = vim.api.nvim_open_win(buf, false, opts)

    -- Set initial content
    local message_index = math.random(#M.funny_messages)
    local content = {
        "",
        "  " .. M.funny_messages[message_index],
        "",
        "  ⏳ Working...",
        "",
    }

    vim.api.nvim_buf_set_option(buf, "modifiable", true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
    vim.api.nvim_buf_set_option(buf, "modifiable", false)

    -- Store state
    M.current_loading = {
        buf = buf,
        win = win,
        message_index = message_index,
        timer = nil
    }

    -- Start message rotation
    M.start_rotation()

    return M.current_loading
end

function M.start_rotation()
    if not M.current_loading then
        return
    end

    -- Use a simpler approach with vim.fn.timer_start but with vim.schedule
    M.current_loading.timer = vim.fn.timer_start(2000, function()
        vim.schedule(function()
            -- Check if loading is still active
            if not M.current_loading or not vim.api.nvim_buf_is_valid(M.current_loading.buf) then
                return
            end

            -- Next message
            M.current_loading.message_index = M.current_loading.message_index + 1
            if M.current_loading.message_index > #M.funny_messages then
                M.current_loading.message_index = 1
            end

            local new_message = M.funny_messages[M.current_loading.message_index]
            print("Updating to message: " .. new_message) -- Debug print
            
            -- Update content
            local content = {
                "",
                "  " .. new_message,
                "",
                "  ⏳ Working...",
                "",
            }

            vim.api.nvim_buf_set_option(M.current_loading.buf, "modifiable", true)
            vim.api.nvim_buf_set_lines(M.current_loading.buf, 0, -1, false, content)
            vim.api.nvim_buf_set_option(M.current_loading.buf, "modifiable", false)
        end)
    end, { ["repeat"] = -1 })
end

function M.hide_loading()
    if not M.current_loading then
        return
    end

    print("Hiding loading screen...") -- Debug print

    -- Stop timer
    if M.current_loading.timer then
        vim.fn.timer_stop(M.current_loading.timer)
    end

    -- Close window
    if M.current_loading.win and vim.api.nvim_win_is_valid(M.current_loading.win) then
        vim.api.nvim_win_close(M.current_loading.win, true)
    end

    -- Delete buffer  
    if M.current_loading.buf and vim.api.nvim_buf_is_valid(M.current_loading.buf) then
        vim.api.nvim_buf_delete(M.current_loading.buf, { force = true })
    end

    M.current_loading = nil
    print("Loading screen hidden") -- Debug print
end

return M