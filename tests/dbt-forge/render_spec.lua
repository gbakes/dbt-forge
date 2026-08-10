local render = require("dbt-forge.render")
local lineage = require("dbt-forge.lineage")
local manifest = require("dbt-forge.manifest")
local fixture = require("fixtures.manifest_fixture")

local ALL = { "model", "source", "seed", "snapshot", "exposure" }
local FCT = "model.jaffle_shop.fct_orders"

local function texts(graph, rows, width)
  local out = {}
  for _, row in ipairs(rows) do
    local text = render.format(graph, row, width)
    table.insert(out, text)
  end
  return out
end

describe("render.tree_rows", function()
  local graph, sub, rows

  before_each(function()
    graph = manifest.project(fixture(), ALL)
    sub = lineage.select(graph, FCT, 2, 2)
    rows = render.tree_rows(graph, sub, FCT)
  end)

  it("marks exactly one row as the root", function()
    local roots = 0
    for _, row in ipairs(rows) do
      if row.is_root then roots = roots + 1 end
    end
    assert.are.equal(1, roots)
  end)

  it("emits upstream and downstream headers", function()
    local headers = {}
    for _, row in ipairs(rows) do
      if row.kind == "header" then table.insert(headers, row.text) end
    end
    assert.are.same({ "▲ UPSTREAM", "▼ DOWNSTREAM" }, headers)
  end)

  it("includes every selected node at least once", function()
    local seen = {}
    for _, row in ipairs(rows) do
      if row.kind == "node" then seen[row.id] = true end
    end
    for id in pairs(sub.depth) do
      assert.is_true(seen[id] == true, "missing " .. id)
    end
  end)

  it("uses └─ for the last child at a level and ├─ otherwise", function()
    local gutters = {}
    for _, row in ipairs(rows) do
      if row.kind == "node" and not row.is_root then
        table.insert(gutters, row.gutter)
      end
    end
    local has_tee, has_elbow = false, false
    for _, g in ipairs(gutters) do
      if g:find("├─", 1, true) then has_tee = true end
      if g:find("└─", 1, true) then has_elbow = true end
    end
    assert.is_true(has_tee)
    assert.is_true(has_elbow)
  end)

  it("produces deterministic output across runs", function()
    local again = render.tree_rows(graph, lineage.select(graph, FCT, 2, 2), FCT)
    assert.are.same(texts(graph, rows, 48), texts(graph, again, 48))
  end)
end)

describe("render.format", function()
  local graph

  before_each(function()
    graph = manifest.project(fixture(), ALL)
  end)

  it("renders a node as gutter, glyph, name and materialization", function()
    local text = render.format(graph, {
      kind = "node", id = FCT, gutter = "├─ ", is_root = false,
    }, 48)
    assert.is_truthy(text:find("●", 1, true))
    assert.is_truthy(text:find("fct_orders", 1, true))
    assert.is_truthy(text:find("table", 1, true))
  end)

  it("uses the root glyph for the root row", function()
    local text = render.format(graph, {
      kind = "node", id = FCT, gutter = "", is_root = true,
    }, 48)
    assert.is_truthy(text:find("◉", 1, true))
  end)

  it("highlights ephemeral models distinctly", function()
    local _, spans = render.format(graph, {
      kind = "node", id = "model.jaffle_shop.int_payments_pivoted",
      gutter = "", is_root = false,
    }, 48)
    local groups = {}
    for _, span in ipairs(spans) do groups[span[1]] = true end
    assert.is_true(groups["DbtForgeLineageEphemeral"] == true)
  end)

  it("highlights sources distinctly", function()
    local _, spans = render.format(graph, {
      kind = "node", id = "source.jaffle_shop.jaffle.orders", gutter = "", is_root = false,
    }, 48)
    local groups = {}
    for _, span in ipairs(spans) do groups[span[1]] = true end
    assert.is_true(groups["DbtForgeLineageSource"] == true)
  end)

  it("renders blank rows as empty strings", function()
    assert.are.equal("", render.format(graph, { kind = "blank" }, 48))
  end)

  it("truncates long names rather than wrapping", function()
    local utf8_len = function(s)
      local _, count = s:gsub("[^\128-\191]", "")
      return count
    end
    local g = { nodes = { ["x"] = {
      name = string.rep("a", 200), resource_type = "model",
      materialized = "table", path = "x.sql",
    } } }
    local text = render.format(g, { kind = "node", id = "x", gutter = "", is_root = false }, 48)
    assert.is_true(utf8_len(text) <= 48)
  end)
end)
