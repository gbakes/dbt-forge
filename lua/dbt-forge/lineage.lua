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

-- A free lane is `false`, never nil: `#t` on a table with nil holes is
-- undefined in Lua and this algorithm indexes by #lanes throughout.
local FREE = false

local function first_free(lanes)
  for i = 1, #lanes do
    if lanes[i] == FREE then
      return i
    end
  end
  return #lanes + 1
end

local function lane_targeting(lanes, id)
  for i = 1, #lanes do
    if lanes[i] == id then
      return i
    end
  end
  return nil
end

-- Assigns each node a rail lane, git-log style. Requires `order` to be
-- topologically sorted so that every edge points downward.
--
-- There is deliberately no `merges` output: because we reuse an already-open
-- lane rather than allocating a second one, and a node's lane stays open until
-- the node itself is emitted, two lanes can never target the same node.
-- Convergence shows up as a split into a pre-existing lane.
function M.assign_lanes(sub, order, root_id)
  local lanes, rows = {}, {}

  for _, node in ipairs(order) do
    -- Claim the lane opened for this node by whichever parent got there first.
    local lane = lane_targeting(lanes, node)
    if not lane then
      lane = first_free(lanes)
    end
    lanes[lane] = FREE

    -- Snapshot occupancy before opening child lanes; this is what the renderer
    -- draws as pass-through rails on this row.
    local occupancy = {}
    for i = 1, #lanes do
      occupancy[i] = lanes[i]
    end

    local splits = {}
    for _, child in ipairs(sub.children[node]) do
      local existing = lane_targeting(lanes, child)
      if existing then
        -- Diamond: the child already has a lane from another parent.
        -- `existing == lane` is unreachable: `lanes[lane]` was just freed
        -- above and nothing between there and here can set it back to this
        -- child's own id before this child's own check runs. Guard kept as
        -- defensive, not load-bearing.
        if existing ~= lane then
          table.insert(splits, existing)
        end
      elseif lanes[lane] == FREE then
        lanes[lane] = child
      else
        local target = first_free(lanes)
        lanes[target] = child
        table.insert(splits, target)
      end
    end

    while #lanes > 0 and lanes[#lanes] == FREE do
      table.remove(lanes)
    end

    table.sort(splits)
    table.insert(rows, {
      id = node,
      lane = lane,
      lanes = occupancy,
      splits = splits,
      depth = sub.depth[node],
      is_root = (node == root_id),
    })
  end

  return rows
end

-- Composes select -> topo_sort -> assign_lanes into the one call the view
-- layer needs. Returns both `rows` (the render-ready lane assignments) and
-- `sub` (the induced subgraph) because a later task needs `sub` too --
-- e.g. to know real parent/child membership independent of lane geometry.
function M.build(graph, root_id, up_depth, down_depth)
  local sub = M.select(graph, root_id, up_depth, down_depth)
  return M.assign_lanes(sub, M.topo_sort(graph, sub), root_id), sub
end

return M
