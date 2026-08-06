local manifest = require("dbt-forge.manifest")
local fixture = require("fixtures.manifest_fixture")

local ALL = { "model", "source", "seed", "snapshot", "exposure" }

describe("manifest.project", function()
  local graph

  before_each(function()
    graph = manifest.project(fixture(), ALL)
  end)

  it("excludes tests from the node set", function()
    assert.is_nil(graph.nodes["test.jaffle_shop.unique_fct_orders_order_id.abc123"])
  end)

  it("excludes tests from the dependency maps", function()
    -- The raw child_map lists a test under fct_orders. Copying the maps
    -- verbatim would give every model phantom test children.
    assert.are.same(
      { "model.jaffle_shop.dim_customers" },
      graph.children["model.jaffle_shop.fct_orders"]
    )
  end)

  it("excludes macros entirely", function()
    assert.is_nil(graph.nodes["macro.dbt.test_unique"])
  end)

  it("retains ephemeral models with their materialization", function()
    local node = graph.nodes["model.jaffle_shop.int_payments_pivoted"]
    assert.is_not_nil(node)
    assert.are.equal("ephemeral", node.materialized)
  end)

  it("defaults models with no configured materialization to view", function()
    assert.are.equal("view", graph.nodes["model.jaffle_shop.legacy_orders"].materialized)
  end)

  it("names sources as source_name.name and types them as source", function()
    local node = graph.nodes["source.jaffle_shop.jaffle.orders"]
    assert.are.equal("jaffle.orders", node.name)
    assert.are.equal("source", node.materialized)
  end)

  it("carries original_file_path through as path", function()
    assert.are.equal(
      "models/marts/fct_orders.sql",
      graph.nodes["model.jaffle_shop.fct_orders"].path
    )
  end)

  it("sorts dependency lists for deterministic output", function()
    assert.are.same({
      "model.jaffle_shop.int_payments_pivoted",
      "model.jaffle_shop.stg_orders",
    }, graph.parents["model.jaffle_shop.fct_orders"])
  end)

  it("gives every retained node both map entries", function()
    for uid in pairs(graph.nodes) do
      assert.is_table(graph.parents[uid], uid .. " missing parents")
      assert.is_table(graph.children[uid], uid .. " missing children")
    end
  end)

  it("indexes nodes by raw name", function()
    assert.are.same({ "model.jaffle_shop.fct_orders" }, graph.by_name["fct_orders"])
  end)

  describe("the include list drives filtering", function()
    it("drops excluded types and any edges touching them", function()
      local models_only = manifest.project(fixture(), { "model" })
      assert.is_nil(models_only.nodes["source.jaffle_shop.jaffle.orders"])
      assert.are.same({}, models_only.parents["model.jaffle_shop.stg_orders"])
    end)
  end)
end)
