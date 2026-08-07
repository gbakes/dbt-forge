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

  it("filters map KEYS: excluded node ids never appear as map keys", function()
    -- The fixture has parent_map["test.jaffle_shop.unique_fct_orders_order_id.abc123"]
    -- present in the raw manifest. If the KEY-side filter is missing, the test id
    -- would appear as a map key. This invariant catches it.
    assert.is_nil(graph.parents["test.jaffle_shop.unique_fct_orders_order_id.abc123"])
    assert.is_nil(graph.children["test.jaffle_shop.unique_fct_orders_order_id.abc123"])

    -- General: all map keys are retained nodes.
    for uid in pairs(graph.parents) do
      assert.is_not_nil(graph.nodes[uid], "parents key " .. uid .. " not in nodes")
    end
    for uid in pairs(graph.children) do
      assert.is_not_nil(graph.nodes[uid], "children key " .. uid .. " not in nodes")
    end
  end)

  it("indexes sources by raw name, not display name", function()
    -- Source raw name is "orders", display name is "jaffle.orders".
    -- by_name must use raw name so Task 4's filename resolution works.
    local source_uid = "source.jaffle_shop.jaffle.orders"
    assert.are.same({ source_uid }, graph.by_name["orders"],
      "by_name should key on raw name 'orders'")
    assert.is_nil(graph.by_name["jaffle.orders"],
      "by_name should NOT key on display name 'jaffle.orders'")
    assert.are.equal("jaffle.orders", graph.nodes[source_uid].name,
      "node.name should be display form 'jaffle.orders'")
  end)

  describe("the include list drives filtering", function()
    it("drops excluded types and any edges touching them", function()
      local models_only = manifest.project(fixture(), { "model" })
      assert.is_nil(models_only.nodes["source.jaffle_shop.jaffle.orders"])
      assert.are.same({}, models_only.parents["model.jaffle_shop.stg_orders"])
    end)
  end)
end)

describe("manifest.resolve", function()
  local ALL_TYPES = { "model", "source", "seed", "snapshot", "exposure" }

  it("resolves an unambiguous name", function()
    local graph = manifest.project(fixture(), ALL_TYPES)
    assert.are.equal(
      "model.jaffle_shop.fct_orders",
      manifest.resolve(graph, "fct_orders", "models/marts/fct_orders.sql")
    )
  end)

  it("disambiguates same-named models by file path", function()
    local raw = fixture()
    raw.nodes["model.other_pkg.fct_orders"] = {
      name = "fct_orders", resource_type = "model", package_name = "other_pkg",
      original_file_path = "models/other/fct_orders.sql",
      config = { materialized = "table" },
    }
    local graph = manifest.project(raw, ALL_TYPES)
    assert.are.equal(
      "model.other_pkg.fct_orders",
      manifest.resolve(graph, "fct_orders", "models/other/fct_orders.sql")
    )
  end)

  it("returns nil for an unknown name", function()
    local graph = manifest.project(fixture(), ALL_TYPES)
    assert.is_nil(manifest.resolve(graph, "no_such_model", "models/nope.sql"))
  end)
end)

describe("manifest.load", function()
  local original_fs_stat, original_json_decode, original_read_file
  local utils = require("dbt-forge.utils")
  local state = { mtime = 1000, size = 1000, decode_fails = 0 }

  before_each(function()
    manifest.invalidate()
    original_fs_stat = vim.loop.fs_stat
    original_json_decode = vim.json.decode
    original_read_file = utils.read_file
    state = { mtime = 1000, size = 1000, decode_fails = 0 }

    -- Mock fs_stat to return controllable mtime
    vim.loop.fs_stat = function(path)
      if path:find("/tmp/") and path:find("target/manifest.json") then
        return { size = state.size, mtime = { sec = state.mtime } }
      end
      return nil
    end

    -- Mock json.decode to return fixture or error
    vim.json.decode = function(content)
      if state.decode_fails > 0 then
        state.decode_fails = state.decode_fails - 1
        error("Simulated decode failure")
      end
      return fixture()
    end

    -- Mock read_file to return dummy content (decode will use fixture instead)
    utils.read_file = function(path)
      if path:find("/tmp/") and path:find("target/manifest.json") then
        return "{}"  -- Content doesn't matter; vim.json.decode is mocked
      end
      return nil
    end
  end)

  after_each(function()
    vim.loop.fs_stat = original_fs_stat
    vim.json.decode = original_json_decode
    utils.read_file = original_read_file
    manifest.invalidate()
  end)

  it("reports a missing manifest rather than erroring", function()
    local graph, err = manifest.load("/definitely/not/a/dbt/project", { "model" })
    assert.is_nil(graph)
    assert.is_string(err)
    assert.is_truthy(err:find("dbt parse"))
  end)

  it("successfully loads and returns a graph with mtime field", function()
    local graph = manifest.load("/tmp/dbt/project", ALL)
    assert.is_not_nil(graph)
    assert.is_table(graph.nodes)
    assert.is_table(graph.by_name)
    assert.is_equal(state.mtime, graph.mtime)
  end)

  it("returns identical cached table on unchanged path+mtime", function()
    local graph1 = manifest.load("/tmp/dbt/project", ALL)
    local graph2 = manifest.load("/tmp/dbt/project", ALL)
    -- rawequal checks object identity, not deep equality
    assert.is_true(rawequal(graph1, graph2))
  end)

  it("cache MISses when mtime changes", function()
    local graph1 = manifest.load("/tmp/dbt/project", ALL)
    state.mtime = 2000
    local graph2 = manifest.load("/tmp/dbt/project", ALL)
    -- Different mtimes means different cache entries
    assert.is_false(rawequal(graph1, graph2))
    assert.is_equal(2000, graph2.mtime)
  end)

  it("cache MISses when path changes, even if mtime unchanged", function()
    local graph1 = manifest.load("/tmp/project-a", ALL)
    local graph2 = manifest.load("/tmp/project-b", ALL)
    -- Different paths means different cache entries, even though mtime is the same
    assert.is_false(rawequal(graph1, graph2))
  end)

  it("invalidate() forces next load to re-read", function()
    local graph1 = manifest.load("/tmp/dbt/project", ALL)
    manifest.invalidate()
    local graph2 = manifest.load("/tmp/dbt/project", ALL)
    -- After invalidate, even with same path+mtime, cache is cleared
    assert.is_false(rawequal(graph1, graph2))
  end)

  it("decode failure with populated cache returns last good copy", function()
    local graph1 = manifest.load("/tmp/dbt/project", ALL)
    state.decode_fails = 1
    state.mtime = 2000
    local graph2, err = manifest.load("/tmp/dbt/project", ALL)
    -- Should return the cached good copy, not an error
    assert.is_not_nil(graph2)
    assert.is_nil(err)
    assert.is_true(rawequal(graph1, graph2))
  end)

  it("decode failure with empty cache returns error", function()
    state.decode_fails = 1
    local graph, err = manifest.load("/tmp/dbt/project", ALL)
    assert.is_nil(graph)
    assert.is_string(err)
    assert.is_truthy(err:find("decode"))
  end)

  it("warns when manifest exceeds 100MB", function()
    state.size = 150 * 1024 * 1024
    local notify_called = false
    local notify_message = ""
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      notify_called = true
      notify_message = msg
    end

    local graph = manifest.load("/tmp/dbt/project", ALL)
    vim.notify = original_notify

    assert.is_true(notify_called)
    assert.is_truthy(notify_message:find("150"))
    assert.is_not_nil(graph)
  end)
end)

describe("manifest.resolve", function()
  local ALL_TYPES = { "model", "source", "seed", "snapshot", "exposure" }

  it("returns first candidate when no path matches", function()
    local raw = fixture()
    raw.nodes["model.other_pkg.fct_orders"] = {
      name = "fct_orders", resource_type = "model", package_name = "other_pkg",
      original_file_path = "models/other/fct_orders.sql",
      config = { materialized = "table" },
    }
    local graph = manifest.project(raw, ALL_TYPES)
    -- Request a path that does not exist in either model
    local result = manifest.resolve(graph, "fct_orders", "models/nonexistent.sql")
    -- Should return the first candidate (sorted deterministically in by_name)
    assert.is_not_nil(result)
    assert.is_string(result)
  end)
end)
