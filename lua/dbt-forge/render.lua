-- Pure presentation. This module must never reference vim.* — it is unit
-- tested under bare luajit with no editor present.
local M = {}

local ROOT_GLYPH = "◉"
local NODE_GLYPH = "●"

local HL_BY_TYPE = {
  source = "DbtForgeLineageSource",
  seed = "DbtForgeLineageSource",
  snapshot = "DbtForgeLineageSource",
  exposure = "DbtForgeLineageSource",
}

-- Lua's `#` counts bytes, but gutters and glyphs are multi-byte UTF-8. These
-- helpers count and slice by character so column maths stays honest.
local function utf8_len(s)
  local _, count = s:gsub("[^\128-\191]", "")
  return count
end

local function utf8_sub(s, chars)
  local count, byte_index = 0, 0
  for i = 1, #s do
    if s:byte(i) < 128 or s:byte(i) >= 192 then
      count = count + 1
      if count > chars then
        return s:sub(1, byte_index)
      end
    end
    byte_index = i
  end
  return s
end

local function hl_for(node, is_root)
  if is_root then
    return "DbtForgeLineageRoot"
  end
  if node.materialized == "ephemeral" then
    return "DbtForgeLineageEphemeral"
  end
  return HL_BY_TYPE[node.resource_type] or "DbtForgeLineageNode"
end

-- Returns the line text plus highlight spans as { hl_group, start_col, end_col }
-- with 0-indexed byte columns and an exclusive end, matching nvim extmarks.
function M.format(graph, row, width)
  local text, spans

  if row.kind == "blank" then
    text, spans = "", {}
  elseif row.kind == "header" then
    text = row.text
    spans = { { "DbtForgeLineageHeader", 0, #row.text } }
  elseif row.kind == "connector" then
    text = row.gutter
    spans = { { "DbtForgeLineageRail", 0, #row.gutter } }
  else
    -- kind == "node" with explicit truncation priority
    local node = graph.nodes[row.id]
    local gutter = row.gutter or ""
    local glyph = row.is_root and ROOT_GLYPH or NODE_GLYPH
    local tag = node.materialized
    -- Rails can sit on BOTH sides of the glyph: the rail renderer reserves a
    -- band for every lane, so lanes to the right of this node's own lane are
    -- drawn between the glyph and the name. `rail_tail` carries those columns
    -- plus the gap before the name, and so subsumes the single separating
    -- space the tree renderer relies on -- hence the default.
    local tail = row.rail_tail or " "

    spans = {}
    local col = 0

    -- Gutter is always included (structure, never truncated)
    if #gutter > 0 then
      table.insert(spans, { "DbtForgeLineageRail", 0, #gutter })
      col = #gutter
    end

    -- Glyph is always included (structure, never truncated)
    table.insert(spans, { hl_for(node, row.is_root), col, col + #glyph })
    col = col + #glyph

    -- Right-hand rails are structure too, and never truncated.
    if #tail > 0 then
      table.insert(spans, { "DbtForgeLineageRail", col, col + #tail })
      col = col + #tail
    end

    -- TRUNCATION PRIORITY — never truncate the name to make room for the
    -- tag. The tag is decoration; the name is what identifies the row. The
    -- tag appears only when the COMPLETE name and the COMPLETE tag both
    -- fit; otherwise it is dropped entirely (never partially). This is
    -- monotonic by construction: as width grows, the number of name
    -- characters shown never decreases, because the name's own branch
    -- (truncated vs. full) depends only on whether the full name fits in
    -- the space after the glyph — not on whether the tag also fits.
    local used_prefix = utf8_len(gutter) + utf8_len(glyph) + utf8_len(tail)
    local available = width - used_prefix  -- space after the glyph, for name (+ tag)
    local tag_len = utf8_len(tag)

    local name = node.name
    local name_len = utf8_len(name)
    local include_tag = false

    if name_len + 1 + tag_len <= available then
      -- Full name AND full tag both fit.
      include_tag = true
    elseif name_len <= available then
      -- Full name fits, but not alongside the tag: drop the tag, never
      -- the name.
      include_tag = false
    else
      -- Even the full name alone doesn't fit: truncate the name (with
      -- ellipsis) and drop the tag — a truncated tag is never shown.
      name = utf8_sub(name, available - 1) .. "…"
      include_tag = false
    end

    table.insert(spans, { hl_for(node, row.is_root), col, col + #name })

    local name_part = gutter .. glyph .. tail .. name
    if include_tag then
      -- Right-align the tag at the requested width so materialization
      -- tags form a scannable column across sibling rows. Safe here: the
      -- both-fit branch above guarantees
      -- width - utf8_len(name_part) - tag_len >= 1.
      local pad = width - utf8_len(name_part) - tag_len
      if pad < 1 then
        pad = 1
      end
      text = name_part .. string.rep(" ", pad) .. tag
      local tag_col = #name_part + pad
      table.insert(spans, { "DbtForgeLineageMaterialization", tag_col, tag_col + #tag })
    else
      text = name_part
    end
  end

  -- FINAL INVARIANT: Ensure text never exceeds width (character count)
  -- This applies to ALL row kinds, not just nodes. If somehow text is over, truncate.
  if utf8_len(text) > width then
    text = utf8_sub(text, width)
  end

  -- Clip all spans to final text bounds: ensure 0 <= start_col <= end_col <= #text
  -- This applies to ALL row kinds. After truncation, spans must be valid.
  local clipped_spans = {}
  local max_byte = #text
  for _, span in ipairs(spans) do
    local hl_group, start_col, end_col = span[1], span[2], span[3]
    if start_col < max_byte then
      -- Span starts within bounds; clamp its end to not exceed text
      end_col = math.min(end_col, max_byte)
      table.insert(clipped_spans, { hl_group, start_col, end_col })
    end
  end

  return text, clipped_spans
end

-- Phase 1 renderer: ancestors as one indented tree, descendants as another.
-- Shared parents are repeated rather than merged; the rail renderer in
-- render.rail_rows draws them as a single node with real edges.
function M.tree_rows(graph, sub, root_id)
  local rows = {}

  local function walk(id, map_key, prefix)
    local kids = sub[map_key][id] or {}
    for i, kid in ipairs(kids) do
      local last = (i == #kids)
      table.insert(rows, {
        kind = "node",
        id = kid,
        gutter = prefix .. (last and "└─ " or "├─ "),
        is_root = false,
      })
      walk(kid, map_key, prefix .. (last and "   " or "│  "))
    end
  end

  local has_upstream = #(sub.parents[root_id] or {}) > 0
  local has_downstream = #(sub.children[root_id] or {}) > 0

  if has_upstream then
    table.insert(rows, { kind = "header", text = "▲ UPSTREAM" })
    walk(root_id, "parents", "")
    table.insert(rows, { kind = "blank" })
  end

  table.insert(rows, { kind = "node", id = root_id, gutter = "", is_root = true })

  if has_downstream then
    table.insert(rows, { kind = "blank" })
    table.insert(rows, { kind = "header", text = "▼ DOWNSTREAM" })
    walk(root_id, "children", "")
  end

  return rows
end

-- ---------------------------------------------------------------------------
-- Phase 2 renderer: the rail graph
-- ---------------------------------------------------------------------------

local RAIL = "│"
local ARM = "─"
local NAME_GAP = "  "

-- Every glyph a connector row can need, keyed by the arms it carries. One
-- table serves all three kinds of cell -- the node's own column, a lane the
-- arm turns down into, and a lane the arm merely crosses -- because a junction
-- is determined by its arms and by nothing else.
local JUNCTION = {
  ["up,down,left,right"] = "┼",
  ["up,down,left"] = "┤",
  ["up,down,right"] = "├",
  ["up,down"] = "│",
  ["up,left,right"] = "┴",
  ["up,left"] = "┘",
  ["up,right"] = "└",
  ["down,left,right"] = "┬",
  ["down,left"] = "┐",
  ["down,right"] = "┌",
  ["left,right"] = "─",
}

local function junction(up, down, left, right)
  local arms = {}
  if up then table.insert(arms, "up") end
  if down then table.insert(arms, "down") end
  if left then table.insert(arms, "left") end
  if right then table.insert(arms, "right") end
  return JUNCTION[table.concat(arms, ",")] or RAIL
end

-- The band is as wide as the widest lane the whole graph ever uses, so every
-- name starts in the same column and a lane's rail runs unbroken from the row
-- that opens it to the row that consumes it.
local function band_width(lane_rows)
  local band = 1
  for _, row in ipairs(lane_rows) do
    if row.lane > band then band = row.lane end
    if #row.lanes > band then band = #row.lanes end
    for _, lane in ipairs(row.splits) do
      if lane > band then band = lane end
    end
  end
  return band
end

-- Rails for a range of lanes as two-column cells. `lead` puts the separator
-- before each cell rather than after, which is what the right of a glyph needs.
local function rails(row, from, to, lead)
  local out = {}
  for i = from, to do
    local cell = row.lanes[i] and RAIL or " "
    if lead then
      table.insert(out, " ")
      table.insert(out, cell)
    else
      table.insert(out, cell)
      table.insert(out, " ")
    end
  end
  return table.concat(out)
end

-- Splits the band around the node's glyph: everything left of it, and
-- everything right of it plus the gap before the name.
local function node_rails(row, band)
  return rails(row, 1, row.lane - 1, false),
    rails(row, row.lane + 1, band, true) .. NAME_GAP
end

-- The connector row drawn beneath a node that opens or joins lanes. Its span
-- covers the node's own lane and every lane it reaches; lanes outside that
-- span keep their rails, because an edge in flight elsewhere does not stop
-- being in flight just because this row is busy.
local function connector_gutter(row, band)
  local targets = {}
  local lo, hi = row.lane, row.lane
  for _, lane in ipairs(row.splits) do
    targets[lane] = true
    if lane < lo then lo = lane end
    if lane > hi then hi = lane end
  end

  -- The horizontal arm runs unbroken from `lo` to `hi`, so every cell in the
  -- span has a left arm unless it starts the span and a right arm unless it
  -- ends it. Only the vertical arms vary by cell.
  local cells = {}
  for i = lo, hi do
    local up, down
    if i == row.lane then
      -- The rail always reaches the node's column from above. Whether it also
      -- leaves below is the one fact the row's geometry cannot supply, which
      -- is why `assign_lanes` records `continues`.
      up, down = true, row.continues
    elseif targets[i] then
      -- A lane the arm turns down into. If that lane was ALREADY open on this
      -- row its rail arrives from above as well, and the junction has to say
      -- so -- a corner glyph here draws a break in a rail that never broke.
      up, down = row.lanes[i] and true or false, true
    else
      -- A lane the arm merely crosses: either open above and below, or empty.
      up = row.lanes[i] and true or false
      down = up
    end
    table.insert(cells, junction(up, down, i > lo, i < hi))
    if i < hi then table.insert(cells, ARM) end
  end

  local text = rails(row, 1, lo - 1, false)
    .. table.concat(cells)
    .. rails(row, hi + 1, band, true)
  return (text:gsub(" +$", ""))
end

-- Phase 2 renderer: one row per node with its rail band in the gutter, plus a
-- connector row wherever a node opens or joins lanes. Connector rows carry no
-- `id`, so line_to_node skips them.
--
-- `graph` and `root_id` are taken for signature symmetry with M.tree_rows; the
-- lane rows already carry every fact this needs.
function M.rail_rows(graph, lane_rows, root_id)
  local band = band_width(lane_rows)
  local rows = {}
  for _, row in ipairs(lane_rows) do
    local gutter, tail = node_rails(row, band)
    table.insert(rows, {
      kind = "node",
      id = row.id,
      gutter = gutter,
      rail_tail = tail,
      is_root = row.is_root,
    })
    if #row.splits > 0 then
      table.insert(rows, { kind = "connector", gutter = connector_gutter(row, band) })
    end
  end
  return rows
end

-- The width this graph actually needs, laid out in full. A float can be far
-- wider than that, and laying out to the window instead would strand every
-- materialization tag a hundred columns from its name. Measured in characters,
-- not bytes: rails and glyphs are 3-byte UTF-8, and a byte count would ask for
-- roughly triple the band width nothing needs.
--
-- Mirrors M.format's own arithmetic, including its `" "` default for a row
-- with no rail_tail, so the two cannot disagree about what a row costs.
function M.natural_width(graph, rows)
  local widest = 1
  for _, row in ipairs(rows) do
    local w
    if row.kind == "node" then
      local node = graph.nodes[row.id]
      local glyph = row.is_root and ROOT_GLYPH or NODE_GLYPH
      w = utf8_len(row.gutter or "")
        + utf8_len(glyph)
        + utf8_len(row.rail_tail or " ")
        + utf8_len(node.name)
        + 1
        + utf8_len(node.materialized)
    elseif row.kind == "header" then
      w = utf8_len(row.text)
    else
      w = utf8_len(row.gutter or "")
    end
    if w > widest then
      widest = w
    end
  end
  return widest
end

return M
