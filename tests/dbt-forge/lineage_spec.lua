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
end)
