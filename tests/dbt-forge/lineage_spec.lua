local lineage = require("dbt-forge.lineage")
local manifest = require("dbt-forge.manifest")
local fixture = require("fixtures.manifest_fixture")

local graph_from_edges = require("fixtures.graph_builder")

local ALL = { "model", "source", "seed", "snapshot", "exposure" }
local FCT = "model.jaffle_shop.fct_orders"

describe("lineage.select", function()
  local graph

  before_each(function()
    graph = manifest.project(fixture(), ALL)
  end)

  it("assigns depth 0 to the root", function()
    local sub = lineage.select(graph, FCT, 2, 2)
    assert.are.equal(0, sub.depth[FCT])
  end)

  it("assigns negative depths upstream and positive downstream", function()
    local sub = lineage.select(graph, FCT, 2, 2)
    assert.are.equal(-1, sub.depth["model.jaffle_shop.stg_orders"])
    assert.are.equal(-2, sub.depth["source.jaffle_shop.jaffle.orders"])
    assert.are.equal(1, sub.depth["model.jaffle_shop.dim_customers"])
  end)

  it("respects the upstream depth cap", function()
    local sub = lineage.select(graph, FCT, 1, 2)
    assert.is_not_nil(sub.depth["model.jaffle_shop.stg_orders"])
    assert.is_nil(sub.depth["source.jaffle_shop.jaffle.orders"])
  end)

  it("respects the downstream depth cap", function()
    local sub = lineage.select(graph, FCT, 2, 0)
    assert.is_nil(sub.depth["model.jaffle_shop.dim_customers"])
  end)

  it("selects only the root at depth 0/0", function()
    local sub = lineage.select(graph, FCT, 0, 0)
    local count = 0
    for _ in pairs(sub.depth) do count = count + 1 end
    assert.are.equal(1, count)
  end)

  it("drops edges pointing at unselected nodes", function()
    -- stg_orders is selected at depth -1 but its own parent is not; the
    -- induced subgraph must not keep that dangling edge.
    local sub = lineage.select(graph, FCT, 1, 1)
    assert.are.same({}, sub.parents["model.jaffle_shop.stg_orders"])
  end)

  it("keeps the smaller absolute depth when a diamond reaches a node twice", function()
    local g = graph_from_edges({ { "a", "b" }, { "b", "c" }, { "a", "c" } })
    local sub = lineage.select(g, "c", 3, 0)
    assert.are.equal(-1, sub.depth["a"])
  end)

  it("keeps the smaller absolute depth in a downstream diamond", function()
    local g = graph_from_edges({ { "a", "b" }, { "a", "c" }, { "b", "d" }, { "c", "d" } })
    local sub = lineage.select(g, "a", 0, 3)
    assert.are.equal(2, sub.depth["d"])
  end)

  it("maintains parent/child symmetry in induced subgraph", function()
    -- Diamond with fan-in and fan-out to ensure real structural complexity
    local g = graph_from_edges({
      { "a", "b" }, { "a", "c" }, { "b", "d" }, { "c", "d" },
      { "d", "e" }, { "d", "f" }, { "e", "g" }, { "f", "g" }
    })
    local sub = lineage.select(g, "d", 2, 2)

    -- Check forward direction: for every parent, child must appear in child's parents
    for uid, children in pairs(sub.children) do
      for _, child in ipairs(children) do
        local parents_of_child = sub.parents[child]
        local found = false
        for _, p in ipairs(parents_of_child) do
          if p == uid then found = true break end
        end
        assert.is_true(found, uid .. " is child of " .. child .. " but not listed as parent")
      end
    end

    -- Check reverse direction: for every child in parents list, parent must appear in that node's children
    for uid, parents in pairs(sub.parents) do
      for _, parent in ipairs(parents) do
        local children_of_parent = sub.children[parent]
        local found = false
        for _, c in ipairs(children_of_parent) do
          if c == uid then found = true break end
        end
        assert.is_true(found, parent .. " is parent of " .. uid .. " but not listed as child")
      end
    end
  end)

  it("maintains symmetry with bidirectional selection", function()
    local g = graph_from_edges({
      { "a", "b" }, { "b", "c" }, { "c", "d" }, { "d", "e" }
    })
    local sub = lineage.select(g, "c", 1, 1)

    -- Should select: a -> b -> c -> d
    -- c at depth 0, b at depth -1, a at depth -2 (not selected), d at depth 1
    assert.are.equal(0, sub.depth["c"])
    assert.are.equal(-1, sub.depth["b"])
    assert.is_nil(sub.depth["a"])
    assert.are.equal(1, sub.depth["d"])

    -- Verify parent/child symmetry
    for uid, children in pairs(sub.children) do
      for _, child in ipairs(children) do
        local parents_of_child = sub.parents[child]
        local found = false
        for _, p in ipairs(parents_of_child) do
          if p == uid then found = true break end
        end
        assert.is_true(found, "Symmetry broken: " .. uid .. " -> " .. child)
      end
    end
  end)
end)

describe("lineage.topo_sort", function()
  local function position_map(order)
    local pos = {}
    for i, id in ipairs(order) do pos[id] = i end
    return pos
  end

  it("places every parent before its child", function()
    local g = graph_from_edges({ { "a", "b" }, { "b", "d" }, { "a", "c" }, { "c", "d" } })
    local sub = lineage.select(g, "a", 0, 3)
    local pos = position_map(lineage.topo_sort(g, sub))
    assert.is_true(pos["a"] < pos["b"])
    assert.is_true(pos["a"] < pos["c"])
    assert.is_true(pos["b"] < pos["d"])
    assert.is_true(pos["c"] < pos["d"])
  end)

  it("emits every selected node exactly once", function()
    local g = graph_from_edges({ { "a", "b" }, { "b", "d" }, { "a", "c" }, { "c", "d" } })
    local sub = lineage.select(g, "a", 0, 3)
    local order = lineage.topo_sort(g, sub)
    assert.are.equal(4, #order)
    local seen = {}
    for _, id in ipairs(order) do
      assert.is_nil(seen[id], id .. " emitted twice")
      seen[id] = true
    end
  end)

  -- Exact expected order, not merely "stable". The depth term is load-bearing
  -- here: once `n` is emitted, the ready set holds `z` (depth 1) and `a`
  -- (depth 2), and only the depth comparison keeps `z` ahead of the
  -- alphabetically-earlier `a`.
  it("emits nodes in a fixed order, shallowest ready node first", function()
    local g = graph_from_edges({ { "m", "n" }, { "m", "z" }, { "n", "a" } })
    local sub = lineage.select(g, "m", 0, 3)
    assert.are.same({ "m", "n", "z", "a" }, lineage.topo_sort(g, sub))
  end)

  -- graph_from_edges sets name == unique_id for every node, so it cannot
  -- express the case the `name` tie-break exists for. Hand-built: the node
  -- whose id sorts LAST has the name that sorts FIRST, so name-ordering and
  -- id-ordering disagree and only a comparator that consults `name` gets
  -- this right.
  it("breaks ties on name before unique_id", function()
    local g = {
      nodes = {
        ["model.pkg.root"] = { name = "root", resource_type = "model" },
        ["model.pkg.zebra"] = { name = "alpha", resource_type = "model" },
        ["model.pkg.alpha"] = { name = "zebra", resource_type = "model" },
      },
      parents = {
        ["model.pkg.root"] = {},
        ["model.pkg.zebra"] = { "model.pkg.root" },
        ["model.pkg.alpha"] = { "model.pkg.root" },
      },
      children = {
        ["model.pkg.root"] = { "model.pkg.alpha", "model.pkg.zebra" },
        ["model.pkg.zebra"] = {},
        ["model.pkg.alpha"] = {},
      },
      by_name = {},
    }
    local sub = lineage.select(g, "model.pkg.root", 0, 1)
    assert.are.same(
      { "model.pkg.root", "model.pkg.zebra", "model.pkg.alpha" },
      lineage.topo_sort(g, sub)
    )
  end)

  it("orders upstream nodes before the root", function()
    local graph = manifest.project(fixture(), ALL)
    local sub = lineage.select(graph, FCT, 2, 2)
    local pos = position_map(lineage.topo_sort(graph, sub))
    assert.is_true(pos["source.jaffle_shop.jaffle.orders"] < pos[FCT])
    assert.is_true(pos["model.jaffle_shop.stg_orders"] < pos[FCT])
    assert.is_true(pos[FCT] < pos["model.jaffle_shop.dim_customers"])
  end)
end)

describe("lineage.assign_lanes", function()
  local function rows_for(edges, root, up, down)
    local g = graph_from_edges(edges)
    local sub = lineage.select(g, root, up, down)
    return lineage.assign_lanes(sub, lineage.topo_sort(g, sub), root), g
  end

  local function by_id(rows)
    local map = {}
    for _, row in ipairs(rows) do map[row.id] = row end
    return map
  end

  it("keeps a linear chain in a single lane", function()
    local rows = rows_for({ { "a", "b" }, { "b", "c" } }, "a", 0, 3)
    for _, row in ipairs(rows) do
      assert.are.equal(1, row.lane)
      assert.are.same({}, row.splits)
    end
  end)

  it("opens a second lane for a fan-out", function()
    local rows = by_id(rows_for({ { "a", "b" }, { "a", "c" } }, "a", 0, 2))
    assert.are.equal(1, rows["a"].lane)
    assert.are.same({ 2 }, rows["a"].splits)
    assert.are.equal(1, rows["b"].lane)
    assert.are.equal(2, rows["c"].lane)
  end)

  it("opens one lane per extra child on a wide fan-out", function()
    local rows = by_id(rows_for({ { "a", "b" }, { "a", "c" }, { "a", "d" } }, "a", 0, 2))
    assert.are.same({ 2, 3 }, rows["a"].splits)
  end)

  it("reuses an existing lane when a diamond reconverges", function()
    -- a→b, a→c, b→d, c→d. Order is a, b, c, d. b opens d's lane; when c is
    -- emitted it must connect across to that lane, not allocate a new one.
    local rows = by_id(rows_for({ { "a", "b" }, { "a", "c" }, { "b", "d" }, { "c", "d" } }, "a", 0, 3))
    assert.are.equal(1, rows["b"].lane)
    assert.are.equal(2, rows["c"].lane)
    assert.are.same({ 1 }, rows["c"].splits)
    assert.are.equal(1, rows["d"].lane)
  end)

  -- Replaces a per-row "two lanes never share a target" check, which cannot
  -- fail: a duplicate target is transient and never lands inside a snapshot,
  -- because a row frees its own lane before the snapshot is taken. What does
  -- survive into the rows is a ghost lane — one left pointing at a node that
  -- has already been emitted. The diamond needs a tail so there is a row
  -- after the convergence for the ghost to appear on.
  it("never leaves a lane pointing at an already-emitted node", function()
    local rows = rows_for({
      { "a", "b" }, { "a", "c" }, { "b", "d" }, { "c", "d" }, { "d", "e" },
    }, "a", 0, 4)
    local emitted = {}
    for _, row in ipairs(rows) do
      for i = 1, #row.lanes do
        local target = row.lanes[i]
        if target then
          assert.is_falsy(
            emitted[target] or target == row.id,
            string.format("row %s: lane %d still targets already-emitted %s",
              row.id, i, tostring(target))
          )
        end
      end
      emitted[row.id] = true
    end
  end)

  it("uses false rather than nil for free lanes", function()
    local rows = rows_for({ { "a", "b" }, { "a", "c" }, { "b", "d" }, { "c", "d" } }, "a", 0, 3)
    for _, row in ipairs(rows) do
      for i = 1, #row.lanes do
        assert.is_not_nil(row.lanes[i], "lane " .. i .. " is a nil hole")
      end
    end
  end)

  -- A lane opened for a node stays occupied while unrelated nodes emit above
  -- it. On a three-way fan-out the order is a, b, c, d: `a` opens lanes 2 and
  -- 3 at once, so lane 3 is held for `d` across BOTH intervening rows. (The
  -- obvious fixture — a long chain beside a single sibling — does not test
  -- this, because topo_sort orders by depth first and emits the shallow
  -- sibling before the chain ever gets deep.)
  it("holds a lane open across intervening rows", function()
    local rows = by_id(rows_for({ { "a", "b" }, { "a", "c" }, { "a", "d" } }, "a", 0, 2))
    assert.are.equal("d", rows["b"].lanes[3])
    assert.are.equal("d", rows["c"].lanes[3])
    assert.are.equal(3, rows["d"].lane)
  end)

  it("marks exactly one row as root", function()
    local rows = rows_for({ { "a", "b" }, { "b", "c" } }, "b", 1, 1)
    local roots = 0
    for _, row in ipairs(rows) do
      if row.is_root then roots = roots + 1 end
    end
    assert.are.equal(1, roots)
  end)

  -- a→b, a→c, b→d. Order is a, b, c, d. `c` closes lane 2 as its LAST act
  -- (no children), leaving lane 2 as a trailing free slot behind `d`'s lane 1
  -- — that trailing slot must be trimmed off before `d` is emitted, or `d`
  -- reports a phantom second rail nothing occupies.
  it("trims a closed trailing lane instead of leaving a phantom rail", function()
    local rows = by_id(rows_for({ { "a", "b" }, { "a", "c" }, { "b", "d" } }, "a", 0, 2))
    assert.are.equal(1, #rows["d"].lanes)
  end)
end)

describe("lineage.build", function()
  it("composes selection, ordering and lane assignment", function()
    local graph = manifest.project(fixture(), ALL)
    local rows = lineage.build(graph, FCT, 2, 2)
    assert.is_true(#rows > 0)
    local ids = {}
    for _, row in ipairs(rows) do ids[row.id] = true end
    assert.is_true(ids[FCT])
    assert.is_true(ids["model.jaffle_shop.dim_customers"])
  end)

  -- `sub` is a deliberate second return value that Task 12 consumes; assert
  -- on its real content, not just its presence, so dropping it or swapping
  -- in the wrong table both fail loudly here rather than in Task 12.
  it("also returns the induced subgraph selection", function()
    local graph = manifest.project(fixture(), ALL)
    local rows, sub = lineage.build(graph, FCT, 2, 2)
    assert.is_true(#rows > 0)
    assert.is_not_nil(sub)
    assert.are.equal(0, sub.depth[FCT])
    assert.are.equal(-1, sub.depth["model.jaffle_shop.stg_orders"])
    assert.is_not_nil(sub.children)
    assert.is_not_nil(sub.parents)
  end)
end)
