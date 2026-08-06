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

return M
