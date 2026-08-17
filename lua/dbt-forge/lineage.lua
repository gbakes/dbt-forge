-- Pure graph layout. This module must never reference vim.* — it is unit
-- tested under bare luajit with no editor present.
local M = {}

-- Walks `graph` outward from `root_id` and returns the depth-bounded induced
-- subgraph: signed depths plus parent/child maps containing only edges whose
-- BOTH endpoints survived selection.
function M.select(graph, root_id, up_depth, down_depth)
  local depth = { [root_id] = 0 }

  local function bfs(map, limit, sign)
    local frontier = { root_id }
    for hop = 1, limit do
      local next_frontier = {}
      for _, id in ipairs(frontier) do
        for _, neighbour in ipairs(map[id] or {}) do
          local d = sign * hop
          if depth[neighbour] == nil or math.abs(d) < math.abs(depth[neighbour]) then
            depth[neighbour] = d
            table.insert(next_frontier, neighbour)
          end
        end
      end
      frontier = next_frontier
      if #frontier == 0 then
        break
      end
    end
  end

  bfs(graph.parents, up_depth, -1)
  bfs(graph.children, down_depth, 1)
  depth[root_id] = 0

  local parents, children = {}, {}
  for id in pairs(depth) do
    parents[id], children[id] = {}, {}
  end
  for id in pairs(depth) do
    for _, child in ipairs(graph.children[id] or {}) do
      if depth[child] ~= nil then
        table.insert(children[id], child)
        table.insert(parents[child], id)
      end
    end
  end
  for _, list in pairs(children) do
    table.sort(list)
  end
  for _, list in pairs(parents) do
    table.sort(list)
  end

  return { depth = depth, parents = parents, children = children }
end

-- Kahn's algorithm. The ordering is what makes rails possible at all: with
-- every parent emitted before its children, all edges point downward in the
-- buffer and no rail ever has to route backwards.
--
-- Ties break on (depth, name, unique_id) — a total order, so output is
-- byte-identical across runs and therefore assertable in tests.
function M.topo_sort(graph, sub)
  local function less(a, b)
    if sub.depth[a] ~= sub.depth[b] then
      return sub.depth[a] < sub.depth[b]
    end
    local name_a = graph.nodes[a] and graph.nodes[a].name or a
    local name_b = graph.nodes[b] and graph.nodes[b].name or b
    if name_a ~= name_b then
      return name_a < name_b
    end
    return a < b
  end

  local indegree, ready = {}, {}
  for id in pairs(sub.depth) do
    indegree[id] = #sub.parents[id]
    if indegree[id] == 0 then
      table.insert(ready, id)
    end
  end
  table.sort(ready, less)

  local order = {}
  while #ready > 0 do
    local node = table.remove(ready, 1)
    table.insert(order, node)
    local unlocked = false
    for _, child in ipairs(sub.children[node]) do
      indegree[child] = indegree[child] - 1
      if indegree[child] == 0 then
        table.insert(ready, child)
        unlocked = true
      end
    end
    -- Re-sorting is O(n log n) per unlock, so worst case O(n² log n). Graphs
    -- here are depth-capped to a few hundred nodes; this is not the bottleneck.
    if unlocked then
      table.sort(ready, less)
    end
  end

  return order
end

return M
