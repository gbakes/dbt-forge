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

function M.run_command_with_callback(cmd, output_callback)
    local job_id = vim.fn.jobstart(cmd, {
        on_stdout = function(_, data)
            if output_callback and data then
                for _, line in ipairs(data) do
                    if line and line ~= "" then
                        output_callback(line)
                    end
                end
            end
        end,
        on_stderr = function(_, data)
            if output_callback and data then
                for _, line in ipairs(data) do
                    if line and line ~= "" then
                        output_callback("ERROR: " .. line)
                    end
                end
            end
        end,
        stdout_buffered = false,
        stderr_buffered = false
    })
    
    return job_id
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

function M.find_dbt_project_path()
  local current_dir = vim.fn.expand("%:p:h")
  
  while current_dir and current_dir ~= "/" do
    local dbt_project_file = current_dir .. "/dbt_project.yml"
    if vim.fn.filereadable(dbt_project_file) == 1 then
      return current_dir
    end
    current_dir = vim.fn.fnamemodify(current_dir, ":h")
  end
  
  return nil
end

function M.detect_python_env()
  local pyenv_version_file = vim.fn.findfile(".python-version", ".;")
  if pyenv_version_file ~= "" then
    local env_name = M.read_file(pyenv_version_file)
    if env_name then
      env_name = env_name:gsub("%s+", "")
      return "pyenv", env_name
    end
  end
  
  local conda_env_file = vim.fn.findfile("environment.yml", ".;")
  if conda_env_file ~= "" then
    local content = M.read_file(conda_env_file)
    if content then
      local env_name = content:match("name:%s*([%w%-_]+)")
      if env_name then
        return "conda", env_name
      end
    end
  end
  
  local venv_dir = vim.fn.finddir("venv", ".;") or vim.fn.finddir(".venv", ".;")
  if venv_dir ~= "" then
    return "venv", vim.fn.fnamemodify(venv_dir, ":p")
  end
  
  return "none", nil
end

function M.get_project_config()
  local dbt_path = M.find_dbt_project_path()
  local env_manager, env_name = M.detect_python_env()
  
  return {
    dbt_project_path = dbt_path,
    python_env_manager = env_manager,
    python_env_name = env_name
  }
end

return M

