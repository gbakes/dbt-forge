-- Builds a manifest-shaped graph directly from adjacency pairs, for algorithm
-- tests that should not depend on the manifest fixture's particular shape.
--
--   graph_builder({ { "a", "b" }, { "b", "c" } })  -- a → b → c
--
-- Node names double as unique_ids, which keeps assertions readable.
return function(edges)
  local nodes, parents, children = {}, {}, {}

  local function ensure(id)
    if not nodes[id] then
      nodes[id] = {
        name = id,
        resource_type = "model",
        materialized = "view",
        path = id .. ".sql",
        package = "test",
      }
      parents[id], children[id] = {}, {}
    end
  end

  for _, edge in ipairs(edges) do
    ensure(edge[1])
    ensure(edge[2])
    table.insert(children[edge[1]], edge[2])
    table.insert(parents[edge[2]], edge[1])
  end

  for _, list in pairs(children) do
    table.sort(list)
  end
  for _, list in pairs(parents) do
    table.sort(list)
  end

  return { nodes = nodes, parents = parents, children = children, by_name = {} }
end
