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

  it("never exceeds width with deep gutter plus long tag", function()
    local utf8_len = function(s)
      local _, count = s:gsub("[^\128-\191]", "")
      return count
    end
    local gutter = "│  │  │  │  ├─ "
    local g = { nodes = { ["x"] = {
      name = "orders", resource_type = "model",
      materialized = "incremental", path = "x.sql",
    } } }
    local text = render.format(g, { kind = "node", id = "x", gutter = gutter, is_root = false }, 20)
    assert.is_true(utf8_len(text) <= 20, "overflow: " .. utf8_len(text) .. " > 20")
  end)

  it("width invariant: character count never exceeds width across range", function()
    local utf8_len = function(s)
      local _, count = s:gsub("[^\128-\191]", "")
      return count
    end
    local g = { nodes = { ["x"] = {
      name = "model_name", resource_type = "model",
      materialized = "table", path = "x.sql",
    } } }
    for _, width in ipairs({ 12, 20, 30, 48, 80 }) do
      local gutter = string.rep("│  ", 5)
      local text = render.format(g, { kind = "node", id = "x", gutter = gutter, is_root = false }, width)
      assert.is_true(utf8_len(text) <= width, "width=" .. width .. " exceeded with " .. utf8_len(text) .. " chars")
    end
  end)

  it("highlight spans stay within text byte bounds after truncation", function()
    local g = { nodes = { ["x"] = {
      name = "a_very_long_model_name_here", resource_type = "model",
      materialized = "incremental", path = "x.sql",
    } } }
    local text, spans = render.format(g, {
      kind = "node", id = "x", gutter = "│  │  ├─ ", is_root = false
    }, 20)
    local max_byte = #text
    for _, span in ipairs(spans) do
      local end_col = span[3]
      assert.is_true(end_col <= max_byte, "span end " .. end_col .. " exceeds text length " .. max_byte)
    end
  end)

  it("both invariants hold across exhaustive property sweep", function()
    local utf8_len = function(s)
      local _, count = s:gsub("[^\128-\191]", "")
      return count
    end
    local node_specs = {
      short = { name="fct", resource_type="model", materialized="table", path="a.sql" },
      long  = { name=string.rep("very_long_model_name_",6), resource_type="model", materialized="incremental", path="b.sql" },
      eph   = { name="int_payments_pivoted_wide", resource_type="model", materialized="ephemeral", path="c.sql" },
      src   = { name="jaffle.orders_with_a_long_table", resource_type="source", materialized="source", path="d.yml" },
    }
    local gutters = { "", "├─ ", "│  ├─ ", "│  │  ├─ ", "│  │  │  ├─ ", "│  │  │  │  ├─ ", string.rep("│  ",10).."└─ " }
    local widths  = { 5, 8, 12, 20, 30, 48, 80 }

    for node_id, node_spec in pairs(node_specs) do
      for _, gutter in ipairs(gutters) do
        for _, width in ipairs(widths) do
          local g = { nodes = { x = node_spec } }
          local text, spans = render.format(g, { kind="node", id="x", gutter=gutter, is_root=false }, width)

          -- Invariant 1: character count never exceeds width
          assert.is_true(utf8_len(text) <= width,
            "overflow: w=" .. width .. " gutter=" .. utf8_len(gutter) .. "ch id=" .. node_id ..
            " -> " .. utf8_len(text) .. " chars")

          -- Invariant 2: all spans end within text bounds
          for _, span in ipairs(spans) do
            local hl_group, start_col, end_col = span[1], span[2], span[3]
            assert.is_true(start_col < #text or #text == 0,
              "dangling span start: w=" .. width .. " gutter=" .. utf8_len(gutter) ..
              "ch id=" .. node_id .. " start=" .. start_col .. " >= #text=" .. #text)
            assert.is_true(end_col <= #text,
              "dangling span end: w=" .. width .. " gutter=" .. utf8_len(gutter) ..
              "ch id=" .. node_id .. " " .. hl_group .. " end=" .. end_col .. " > #text=" .. #text)
          end
        end
      end
    end
  end)

  it("truncation priority: name preserved over tag", function()
    local utf8_len = function(s)
      local _, count = s:gsub("[^\128-\191]", "")
      return count
    end
    local g = { nodes = { x = {
      name = "orders", resource_type = "model", materialized = "incremental", path = "x.sql"
    } } }
    -- At width 20 with deep gutter, name should survive and tag should not appear
    local gutter = "│  │  │  ├─ "  -- 12 chars
    local text = render.format(g, { kind="node", id="x", gutter=gutter, is_root=false }, 20)
    -- Text should include the name "orders" and NOT include the tag "incremental"
    assert.is_truthy(text:find("orders", 1, true), "name missing in truncated output")
    assert.is_falsy(text:find("incremental", 1, true), "tag should be dropped, name should survive")
  end)

  it("truncation priority holds at mid widths too, not just narrow ones", function()
    local g = { nodes = { x = {
      name = "orders", resource_type = "model", materialized = "incremental", path = "x.sql"
    } } }
    -- Reported regression: at width 30 with this gutter, the name collapsed
    -- to a bare "…" while the full tag "incremental" survived intact. The
    -- name must remain the primary identifying content at every width, not
    -- only at the narrowest ones.
    local gutter = "│  │  │  │  ├─ "  -- 15 chars
    local text = render.format(g, { kind = "node", id = "x", gutter = gutter, is_root = false }, 30)
    assert.is_truthy(text:find("orders", 1, true), "name missing at mid width")
    assert.is_falsy(text:find("incremental", 1, true), "tag should be dropped when it would crush the name")
  end)

  it("width invariant holds for all row kinds (nodes, headers, connectors)", function()
    local utf8_len = function(s)
      local _, count = s:gsub("[^\128-\191]", "")
      return count
    end
    local g = { nodes = { x = {
      name = "model_name", resource_type = "model", materialized = "table", path = "x.sql"
    } } }

    -- Test widths and row kinds
    local widths = { 5, 8, 12, 20, 30, 48, 80 }

    for _, width in ipairs(widths) do
      -- Node rows
      local text_node, spans_node = render.format(g, {
        kind = "node", id = "x", gutter = "│  │  ├─ ", is_root = false
      }, width)
      assert.is_true(utf8_len(text_node) <= width,
        "node row overflow at w=" .. width .. ": " .. utf8_len(text_node) .. " chars")
      for _, span in ipairs(spans_node) do
        assert.is_true(span[3] <= #text_node,
          "node span end=" .. span[3] .. " > text=" .. #text_node)
      end

      -- Header rows
      local text_header, spans_header = render.format(g, {
        kind = "header", text = "▲ UPSTREAM MODELS WITH LONG NAME THAT EXCEEDS BOUNDS"
      }, width)
      assert.is_true(utf8_len(text_header) <= width,
        "header row overflow at w=" .. width .. ": " .. utf8_len(text_header) .. " chars")
      for _, span in ipairs(spans_header) do
        assert.is_true(span[3] <= #text_header,
          "header span end=" .. span[3] .. " > text=" .. #text_header)
      end

      -- Connector rows (used by rail renderer in Task 12)
      local text_connector, spans_connector = render.format(g, {
        kind = "connector", gutter = string.rep("│  ", 20)  -- Very wide gutter
      }, width)
      assert.is_true(utf8_len(text_connector) <= width,
        "connector row overflow at w=" .. width .. ": " .. utf8_len(text_connector) .. " chars")
      for _, span in ipairs(spans_connector) do
        assert.is_true(span[3] <= #text_connector,
          "connector span end=" .. span[3] .. " > text=" .. #text_connector)
      end
    end
  end)

  it("visible name length is monotonically non-decreasing as width grows", function()
    -- The bug class this closes: a hard cutover on "does the tag fit" makes
    -- the displayed name SHRINK as width GROWS past the point the tag
    -- starts fitting (name truncated to squeeze the tag in). The rule must
    -- guarantee the number of name characters shown never regresses as
    -- width increases, for any name/tag/gutter combination — not just the
    -- specific widths that were reported broken.
    local rows = {
      { name = "orders", materialized = "incremental", gutter = "│  │  │  │  ├─ " },
      { name = "fct_customer_orders", materialized = "view", gutter = "│  │  ├─ " },
      { name = "stg_payments", materialized = "view", gutter = "├─ " },
      { name = "int_payments_pivoted_wide_example", materialized = "ephemeral", gutter = "" },
    }

    for _, spec in ipairs(rows) do
      local g = { nodes = { x = {
        name = spec.name, resource_type = "model", materialized = spec.materialized, path = "x.sql",
      } } }
      local prefix = spec.gutter .. "●" .. " "
      local prev_visible = -1

      for width = 1, 100 do
        local text = render.format(g, { kind = "node", id = "x", gutter = spec.gutter, is_root = false }, width)

        -- Longest byte-prefix of the name that appears intact right after
        -- the (never-truncated) gutter + glyph + space. Names in this test
        -- are plain ASCII so byte comparison is character-accurate.
        local visible = 0
        if text:sub(1, #prefix) == prefix then
          local rest = text:sub(#prefix + 1)
          for i = 1, #spec.name do
            if rest:sub(i, i) == spec.name:sub(i, i) then
              visible = visible + 1
            else
              break
            end
          end
        end

        assert.is_true(visible >= prev_visible, string.format(
          "name=%s width=%d: visible name chars dropped from %d to %d (text=%q)",
          spec.name, width, prev_visible, visible, text))
        prev_visible = visible
      end
    end
  end)

  it("a shown tag never implies a truncated name", function()
    local rows = {
      { name = "orders", materialized = "incremental", gutter = "│  │  │  │  ├─ " },
      { name = "fct_customer_orders", materialized = "view", gutter = "│  │  ├─ " },
      { name = "stg_payments", materialized = "view", gutter = "├─ " },
    }

    for _, spec in ipairs(rows) do
      local g = { nodes = { x = {
        name = spec.name, resource_type = "model", materialized = spec.materialized, path = "x.sql",
      } } }

      for width = 1, 100 do
        local text = render.format(g, { kind = "node", id = "x", gutter = spec.gutter, is_root = false }, width)
        if text:find(spec.materialized, 1, true) then
          assert.is_truthy(text:find(spec.name, 1, true), string.format(
            "name=%s width=%d: tag shown but full name absent (text=%q)", spec.name, width, text))
          assert.is_falsy(text:find("…", 1, true), string.format(
            "name=%s width=%d: tag shown alongside a truncated (ellipsis) name (text=%q)", spec.name, width, text))
        end
      end
    end
  end)
end)
