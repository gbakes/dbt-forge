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

return M
