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

    spans = {}
    local col = 0

    -- Gutter is always included (structure, never truncated)
    if #gutter > 0 then
      table.insert(spans, { "DbtForgeLineageRail", 0, #gutter })
      col = #gutter
    end

    -- Glyph is always included (structure, never truncated)
    table.insert(spans, { hl_for(node, row.is_root), col, col + #glyph })
    col = col + #glyph + 1

    -- TRUNCATION PRIORITY — never truncate the name to make room for the
    -- tag. The tag is decoration; the name is what identifies the row. The
    -- tag appears only when the COMPLETE name and the COMPLETE tag both
    -- fit; otherwise it is dropped entirely (never partially). This is
    -- monotonic by construction: as width grows, the number of name
    -- characters shown never decreases, because the name's own branch
    -- (truncated vs. full) depends only on whether the full name fits in
    -- the space after the glyph — not on whether the tag also fits.
    local used_prefix = utf8_len(gutter) + utf8_len(glyph) + 1  -- gutter + glyph + space
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

    local name_part = gutter .. glyph .. " " .. name
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

return M
