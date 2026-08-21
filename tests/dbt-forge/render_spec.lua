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

describe("render.rail_rows", function()
  local graph_from_edges = require("fixtures.graph_builder")

  -- A diamond exercises every rail feature at once. Lane assignment for
  -- a -> {b, c}, b -> d, c -> d is:
  --
  --   a  lane 1  splits {2}  continues     (opens lane 2 for c)
  --   b  lane 1              continues     (hands lane 1 to d; c waits in 2)
  --   c  lane 2  splits {1}  ends          (d already holds lane 1)
  --   d  lane 1              ends
  --
  -- so the rendered band is two lanes wide throughout.
  local DIAMOND = { { "a", "b" }, { "a", "c" }, { "b", "d" }, { "c", "d" } }

  -- Width 10 is deliberate: wide enough for these one-character names, too
  -- narrow for the "view" materialization tag, so lines carry rails and name
  -- only and can be asserted verbatim.
  local WIDTH = 10

  local function lines(edges, root, up, down)
    local g = graph_from_edges(edges)
    local lane_rows = lineage.build(g, root, up, down)
    return texts(g, render.rail_rows(g, lane_rows, root), WIDTH)
  end

  local function rows_of(edges, root, up, down)
    local g = graph_from_edges(edges)
    return render.rail_rows(g, lineage.build(g, root, up, down), root)
  end

  it("emits one node row per graph node", function()
    local rows = rows_of({ { "a", "b" }, { "b", "c" } }, "a", 0, 3)
    local nodes = 0
    for _, row in ipairs(rows) do
      if row.kind == "node" then nodes = nodes + 1 end
    end
    assert.are.equal(3, nodes)
  end)

  it("emits no connector rows for a linear chain", function()
    for _, row in ipairs(rows_of({ { "a", "b" }, { "b", "c" } }, "a", 0, 3)) do
      assert.are_not.equal("connector", row.kind)
    end
  end)

  it("leaves connector rows without an id so line_to_node skips them", function()
    local connectors = 0
    for _, row in ipairs(rows_of({ { "a", "b" }, { "a", "c" } }, "a", 0, 2)) do
      if row.kind == "connector" then
        connectors = connectors + 1
        assert.is_nil(row.id)
      end
    end
    assert.are.equal(1, connectors)
  end)

  it("aligns every node's name at the same column regardless of its lane", function()
    -- The band is reserved for all lanes, so a lane-1 node and a lane-2 node
    -- start their names in the same column. This is the whole point of the
    -- band: under a break-at-lane gutter these two differ by two columns.
    local out = lines(DIAMOND, "a", 0, 3)
    assert.are.equal("● │  b", out[3])
    assert.are.equal("│ ●  c", out[4])
  end)

  it("draws a pass-through rail for a lane held open to the right of the node", function()
    -- b sits in lane 1 while c still waits in lane 2. Under a gutter that
    -- stops at the node's own lane, that rail vanishes from this row.
    local out = lines(DIAMOND, "a", 0, 3)
    assert.is_truthy(out[3]:find("│", 1, true), "no pass-through rail on b's row: " .. out[3])
  end)

  it("opens a rightward split beneath the node's lane", function()
    local out = lines(DIAMOND, "a", 0, 3)
    assert.are.equal("├─┐", out[2])
  end)

  it("turns a leftward merge down into the lane it joins", function()
    -- c's only child already holds lane 1, so the rail leaves c heading left
    -- and c's own lane ends: at lane 2 the arm arrives from above and stops.
    -- Lane 1 is NOT a fresh corner -- d has been waiting there since b's row,
    -- so that rail arrives from above too and the arm joins it: up+down+right.
    -- A corner glyph here would draw a break in a rail that never broke.
    local out = lines(DIAMOND, "a", 0, 3)
    assert.are.equal("├─┘", out[5])
  end)

  it("keeps the up-arm when a merge rejoins a lane that is already open", function()
    -- a opens lane 2 for c, then b (lane 1) finds its only child c already
    -- waiting there and merges rightward into it. Lane 2's rail has been
    -- running since a's row, so the junction b merges into carries up, down
    -- and left -- a tee, not the corner that would start a fresh lane.
    local out = lines({ { "a", "b" }, { "a", "c" }, { "b", "c" } }, "a", 0, 3)
    assert.are.equal("└─┤", out[4])
  end)

  it("passes the arm through an intermediate lane rather than dead-ending on it", function()
    -- a fans out to three lanes. The arm has to reach lane 3, so at lane 2 it
    -- turns down AND carries on right: that is a T, not a corner. A corner
    -- there draws a rail whose horizontal line stops at a glyph that has no
    -- opening on its right, while the arm visibly continues past it.
    local out = lines({ { "a", "b" }, { "a", "c" }, { "a", "d" } }, "a", 0, 2)
    assert.are.equal("├─┬─┐", out[2])
  end)

  it("crosses a lane the arm passes over without severing it", function()
    -- a opens lane 2 for c; b (lane 1) then fans out to d and e, and e can
    -- only go to lane 3 because c still holds lane 2. b's arm therefore has to
    -- reach *over* lane 2, whose rail runs on down to c below. The crossing
    -- cell keeps all four arms; anything less cuts c's rail in half.
    local out = lines({ { "a", "b" }, { "a", "c" }, { "b", "d" }, { "b", "e" } }, "a", 0, 3)
    assert.are.equal("├─┼─┐", out[4])
  end)

  it("leaves no trailing whitespace where a connector stops short of the band", function()
    -- Same graph as above, so the band is three lanes wide, but a's connector
    -- only spans lanes 1-2 and lane 3 is empty beneath it. Those two columns
    -- carry nothing and must not be written out as trailing blanks.
    local out = lines({ { "a", "b" }, { "a", "c" }, { "b", "d" }, { "b", "e" } }, "a", 0, 3)
    assert.are.equal("├─┐", out[2])
  end)

  it("keeps drawing lanes that lie outside a connector's own span", function()
    -- c (lane 2) splits right into lane 3 while z still occupies lane 1.
    -- The connector spans lanes 2-3 only, but lane 1's rail must survive it.
    local out = lines(
      { { "a", "b" }, { "a", "c" }, { "b", "z" }, { "c", "d" }, { "c", "e" } }, "a", 0, 3)
    local connector
    for i, text in ipairs(out) do
      if i > 2 and text:find("┐", 1, true) then connector = text end
    end
    assert.is_not_nil(connector, "expected a second split connector")
    assert.are.equal("│ ├─┐", connector)
  end)
end)

describe("render.natural_width", function()
  local graph_from_edges = require("fixtures.graph_builder")

  -- The width a graph actually needs, so a float wider than that does not
  -- right-align materialization tags a hundred columns from their names.
  it("measures the widest row: band, glyph, name, gap and tag", function()
    local g = graph_from_edges({ { "a", "bbbbbbbb" } })
    -- Single lane, so band 1: gutter "" + glyph 1 + tail 2 = 3 prefix.
    -- Widest name is "bbbbbbbb" (8), tag "view" (4), one space between.
    assert.are.equal(3 + 8 + 1 + 4, render.natural_width(g, render.rail_rows(
      g, lineage.build(g, "a", 0, 1), "a")))
  end)

  it("grows with the rail band, not just with the name", function()
    local narrow = graph_from_edges({ { "a", "b" } })
    local wide = graph_from_edges({ { "a", "b" }, { "a", "c" }, { "a", "d" } })
    local function nat(g, root, down)
      return render.natural_width(g, render.rail_rows(g, lineage.build(g, root, 0, down), root))
    end
    -- Same one-character names either side; only the lane count differs.
    assert.is_true(nat(wide, "a", 1) > nat(narrow, "a", 1))
  end)

  it("counts characters rather than bytes in the multibyte band", function()
    -- Rails and glyphs are 3-byte UTF-8. A byte count would roughly triple
    -- the band's contribution and hand a float a width nothing needs.
    local g = graph_from_edges({ { "a", "b" }, { "a", "c" } })
    local rows = render.rail_rows(g, lineage.build(g, "a", 0, 1), "a")
    local width = render.natural_width(g, rows)
    -- band 2 -> prefix 5 ("● │" + 2 gap), name 1, gap 1, tag 4 = 11.
    assert.are.equal(11, width)
  end)

  it("counts the left gutter when the widest row is not in lane 1", function()
    -- "cccccccccc" sorts after "b", so it lands in lane 2 and its row carries
    -- a two-column left gutter that lane-1 rows do not. Measuring only the
    -- right of the glyph undercounts precisely the widest row.
    local g = graph_from_edges({ { "a", "b" }, { "a", "cccccccccc" } })
    local rows = render.rail_rows(g, lineage.build(g, "a", 0, 1), "a")
    -- gutter 2 + glyph 1 + tail 2 + name 10 + gap 1 + tag 4
    assert.are.equal(2 + 1 + 2 + 10 + 1 + 4, render.natural_width(g, rows))
  end)

  it("covers header rows from the tree renderer", function()
    -- "▼ DOWNSTREAM" is 12 characters and carries no tag; a graph of
    -- one-character names must still be wide enough to show it.
    local g = graph_from_edges({ { "a", "b" } })
    local sub = lineage.select(g, "a", 0, 1)
    assert.is_true(render.natural_width(g, render.tree_rows(g, sub, "a")) >= 12)
  end)
end)
