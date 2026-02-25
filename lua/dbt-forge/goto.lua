local M = {}

local config = require("dbt-forge.config")
local utils = require("dbt-forge.utils")

local BUILTINS = {
  "ref", "source", "config", "var", "env_var", "log",
  "return", "exceptions", "adapter", "set", "if", "for",
  "block", "macro", "call", "filter", "is_incremental",
  "this", "target", "run_query", "statement",
}

local function is_builtin(name)
  for _, b in ipairs(BUILTINS) do
    if name == b then
      return true
    end
  end
  return false
end

local function parse_reference_at_cursor()
  local line = vim.api.nvim_get_current_line()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local col = cursor[2] + 1 -- convert to 1-indexed

  -- Find the {{ ... }} block containing the cursor
  local jinja_expr = nil
  local search_start = 1
  while true do
    local open_start, open_end = line:find("{{", search_start, true)
    if not open_start then break end
    local close_start, close_end = line:find("}}", open_end + 1, true)
    if not close_start then break end

    if col >= open_start and col <= close_end then
      jinja_expr = line:sub(open_end + 1, close_start - 1)
      break
    end
    search_start = close_end + 1
  end

  if not jinja_expr then
    return nil
  end

  jinja_expr = vim.trim(jinja_expr)

  -- Pattern 1: ref('model_name') or ref("model_name")
  local ref_model = jinja_expr:match("ref%s*%(%s*['\"]([%w_%-]+)['\"]%s*%)")
  if ref_model then
    return { type = "ref", model = ref_model }
  end

  -- Pattern 2: source('namespace', 'table_name')
  local src_namespace, src_table = jinja_expr:match(
    "source%s*%(%s*['\"]([%w_%-]+)['\"]%s*,%s*['\"]([%w_%-]+)['\"]%s*%)"
  )
  if src_namespace and src_table then
    return { type = "source", namespace = src_namespace, table_name = src_table }
  end

  -- Pattern 3: package.macro_name(...) — external package macro
  local pkg, macro_name = jinja_expr:match("^([%w_]+)%.([%w_]+)%s*%(")
  if pkg and macro_name then
    return { type = "package_macro", package = pkg, macro = macro_name }
  end

  -- Pattern 4: macro_name(...) — custom macro
  local custom_macro = jinja_expr:match("^([%w_]+)%s*%(")
  if custom_macro and not is_builtin(custom_macro) then
    return { type = "macro", macro = custom_macro }
  end

  return nil
end

local function resolve_ref(model_name)
  local project_path = config.options.dbt_project_path
  if not project_path then return nil end

  local models_dir = project_path .. "/models"
  local matches = vim.fn.globpath(models_dir, "**/" .. model_name .. ".sql", false, true)

  if #matches == 0 then
    return nil
  end

  return { file = matches[1], line = 1 }
end

local function resolve_source(namespace, table_name)
  local project_path = config.options.dbt_project_path
  if not project_path then return nil end

  local models_dir = project_path .. "/models"
  local yml_files = vim.fn.globpath(models_dir, "**/*.yml", false, true)
  local yaml_files = vim.fn.globpath(models_dir, "**/*.yaml", false, true)
  vim.list_extend(yml_files, yaml_files)

  local ns_pattern = "%-%s*name:%s*" .. vim.pesc(namespace)
  local tbl_pattern = "%-%s*name:%s*" .. vim.pesc(table_name)

  for _, yml_path in ipairs(yml_files) do
    local content = utils.read_file(yml_path)
    if not content then goto continue end

    -- Quick check: does this file mention the namespace?
    if not content:find(namespace, 1, true) then goto continue end

    local lines = vim.split(content, "\n")
    local found_namespace = false
    local in_tables_section = false

    for i, line in ipairs(lines) do
      if line:match(ns_pattern) then
        found_namespace = true
        in_tables_section = false
      end

      if found_namespace and line:match("^%s+tables:") then
        in_tables_section = true
      end

      if found_namespace and in_tables_section then
        if line:match(tbl_pattern) then
          return { file = yml_path, line = i }
        end
      end
    end

    ::continue::
  end

  return nil
end

local function resolve_macro(macro_name, package_name)
  local project_path = config.options.dbt_project_path
  if not project_path then return nil end

  local search_dir
  if package_name then
    search_dir = project_path .. "/dbt_packages"
  else
    search_dir = project_path .. "/macros"
  end

  if vim.fn.isdirectory(search_dir) == 0 then
    return nil
  end

  local sql_files = vim.fn.globpath(search_dir, "**/*.sql", false, true)

  local pattern = "{%%%s*macro%s+" .. vim.pesc(macro_name) .. "%s*%("
  local pattern_trim = "{%%%-?%s*macro%s+" .. vim.pesc(macro_name) .. "%s*%("

  for _, sql_path in ipairs(sql_files) do
    -- For package macros, filter by package directory name
    if package_name then
      local normalized_pkg = package_name:gsub("[-_]", "[-_]")
      if not sql_path:match("/dbt_packages/" .. normalized_pkg .. "/") then
        goto continue
      end
    end

    local content = utils.read_file(sql_path)
    if not content then goto continue end

    local lines = vim.split(content, "\n")
    for i, line in ipairs(lines) do
      if line:match(pattern) or line:match(pattern_trim) then
        return { file = sql_path, line = i }
      end
    end

    ::continue::
  end

  return nil
end

function M.goto_definition()
  if not utils.is_sql_file() then
    vim.cmd("normal! gd")
    return
  end

  local project_path = config.options.dbt_project_path
  if not project_path then
    vim.notify("dbt-forge: No dbt project path configured", vim.log.levels.WARN)
    return
  end

  local ref = parse_reference_at_cursor()
  if not ref then
    -- Not on a Jinja reference, fall back to native gd
    local ok, _ = pcall(vim.cmd, "normal! gd")
    if not ok then
      vim.notify("dbt-forge: No definition found", vim.log.levels.INFO)
    end
    return
  end

  local result = nil
  local label = ""

  if ref.type == "ref" then
    result = resolve_ref(ref.model)
    label = ref.model
  elseif ref.type == "source" then
    result = resolve_source(ref.namespace, ref.table_name)
    label = ref.namespace .. "." .. ref.table_name
  elseif ref.type == "package_macro" then
    result = resolve_macro(ref.macro, ref.package)
    label = ref.package .. "." .. ref.macro
  elseif ref.type == "macro" then
    result = resolve_macro(ref.macro, nil)
    label = ref.macro
  end

  if result then
    vim.cmd("edit " .. vim.fn.fnameescape(result.file))
    if result.line then
      vim.api.nvim_win_set_cursor(0, { result.line, 0 })
      vim.cmd("normal! zz")
    end
  else
    vim.notify(
      string.format("dbt-forge: Could not find definition for '%s'", label),
      vim.log.levels.WARN
    )
  end
end

-- Exposed for testing
M._parse_reference_at_cursor = parse_reference_at_cursor
M._resolve_ref = resolve_ref
M._resolve_source = resolve_source
M._resolve_macro = resolve_macro

return M
