local M = {}
local config = require("dbt-forge.config")

function M.is_sql_file()
    return vim.fn.expand("%:e") == "sql"
end

function M.run_command(cmd)
    local handle = io.popen(cmd)
    if not handle then
        return nil
    end
    local result = handle:read("*a")
    local success = handle:close()
    return success and result or nil
end

function M.read_file(filepath)
    local file = io.open(filepath, "r")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    return content
end

function M.build_dbt_command(dbt_cmd)
    local base_cmd = string.format("cd %s", config.options.dbt_project_path)
    local env_cmd = ""
    if config.options.python_env_manager == "pyenv" and config.options.python_env_name then
        env_cmd = string.format('eval "$(pyenv init -)" && pyenv activate %s', config.options.python_env_name)
    elseif config.options.python_env_manager == "conda" and config.options.python_env_name then
        env_cmd = string.format("conda activate %s", config.options.python_env_name)
    elseif config.options.python_env_manager == "venv" and config.options.python_env_name then
        env_cmd = string.format("source %s/bin/activate", config.options.python_env_name)
    end
    if env_cmd ~= "" then
        return string.format("%s && %s && %s", base_cmd, env_cmd, dbt_cmd)
    else
        return string.format("%s && %s", base_cmd, dbt_cmd)
    end
end

function M.find_compiled_file(filename)
    local find_cmd = string.format(
        'find %s/target/compiled -name "%s.sql" -type f | head -1',
        config.options.dbt_project_path,
        filename
    )
    local result = M.run_command(find_cmd)
    if not result or result == "" then
        return nil
    end
    return result:gsub("\n", "")
end

return M

