local M = {}

local function display_name(node)
  if node.resource_type == "source" then
    return (node.source_name or "?") .. "." .. node.name
  end
  return node.name
end

local function materialization(node)
  if node.resource_type == "model" then
    -- dbt's own default when a model configures nothing.
    return (node.config and node.config.materialized) or "view"
  end
  return node.resource_type
end

-- Projects a decoded manifest into the compact graph the lineage view needs.
-- Pure: takes an already-decoded table, touches no IO and no vim API.
function M.project(raw, include)
  local allow = {}
  for _, resource_type in ipairs(include) do
    allow[resource_type] = true
  end

  local nodes, by_name = {}, {}

  local function take(collection)
    for uid, node in pairs(collection or {}) do
      if allow[node.resource_type] then
        nodes[uid] = {
          name = display_name(node),
          resource_type = node.resource_type,
          materialized = materialization(node),
          path = node.original_file_path,
          package = node.package_name,
        }
        by_name[node.name] = by_name[node.name] or {}
        table.insert(by_name[node.name], uid)
      end
    end
  end

  take(raw.nodes)
  take(raw.sources)
  take(raw.exposures)

  -- Filter both ends of every edge. parent_map/child_map contain test node
  -- ids; copying them verbatim gives every model phantom test children.
  local function filter_map(source_map)
    local out = {}
    for uid, list in pairs(source_map or {}) do
      if nodes[uid] then
        local kept = {}
        for _, other in ipairs(list) do
          if nodes[other] then
            table.insert(kept, other)
          end
        end
        table.sort(kept)
        out[uid] = kept
      end
    end
    return out
  end

  local parents = filter_map(raw.parent_map)
  local children = filter_map(raw.child_map)

  -- Guarantee every node has both entries so callers never nil-check.
  for uid in pairs(nodes) do
    parents[uid] = parents[uid] or {}
    children[uid] = children[uid] or {}
  end
  for _, ids in pairs(by_name) do
    table.sort(ids)
  end

  return { nodes = nodes, parents = parents, children = children, by_name = by_name }
end

local uv = vim.uv or vim.loop
local utils = require("dbt-forge.utils")

-- Decoding is the expensive step, so hold one projected graph keyed on the
-- manifest's mtime. Re-opening the sidebar on an unchanged manifest is a
-- table lookup.
local cache = { path = nil, mtime = nil, graph = nil }

local MAX_BYTES = 100 * 1024 * 1024

function M.invalidate()
  cache = { path = nil, mtime = nil, graph = nil }
end

function M.load(project_path, include)
  local path = project_path .. "/target/manifest.json"

  local stat = uv.fs_stat(path)
  if not stat then
    return nil, "No target/manifest.json — run `dbt parse`, or press R"
  end

  local mtime = stat.mtime.sec
  if cache.path == path and cache.mtime == mtime and cache.graph then
    return cache.graph
  end

  if stat.size > MAX_BYTES then
    vim.notify(
      string.format(
        "dbt-forge: manifest.json is %.0fMB — this may take a moment",
        stat.size / 1024 / 1024
      ),
      vim.log.levels.WARN
    )
  end

  local content = utils.read_file(path)
  if not content then
    return nil, "Could not read " .. path
  end

  local ok, raw = pcall(vim.json.decode, content)
  if not ok then
    -- Most likely caught mid-write by a concurrent dbt run.
    if cache.graph then
      vim.notify(
        "dbt-forge: manifest.json unreadable — using last good copy",
        vim.log.levels.WARN
      )
      return cache.graph
    end
    return nil, "Could not decode manifest.json"
  end

  local graph = M.project(raw, include)
  graph.mtime = mtime

  -- Peak memory is the decoded blob, which is many times larger than the
  -- projection. Drop the reference before returning so it can be collected.
  raw = nil
  content = nil

  cache = { path = path, mtime = mtime, graph = graph }
  return graph
end

-- Maps a buffer filename to a node, preferring an exact file-path match when
-- two packages define the same model name.
function M.resolve(graph, name, rel_path)
  local ids = graph.by_name[name]
  if not ids or #ids == 0 then
    return nil
  end
  if #ids == 1 then
    return ids[1]
  end
  for _, id in ipairs(ids) do
    if graph.nodes[id].path == rel_path then
      return id
    end
  end
  return ids[1]
end

return M
