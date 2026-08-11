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

    -- TRUNCATION PRIORITY:
    -- 1. Never truncate gutter or glyph (done above)
    -- 2. Keep name if space allows (at least 1 char + ellipsis)
    -- 3. Drop tag entirely before eating the name
    -- 4. Only raw chop if glyph alone doesn't fit

    local used_prefix = utf8_len(gutter) + utf8_len(glyph) + 1  -- gutter + glyph + space
    local tag_len = utf8_len(tag)

    -- Space for name and tag, accounting for spaces between them
    local space_for_name_and_tag = width - used_prefix

    local name = node.name
    local include_tag = false

    if space_for_name_and_tag > 0 then
      -- We have space for at least something
      if space_for_name_and_tag >= tag_len + 1 then
        -- Enough space for tag + space before it; also fit name if possible
        local name_budget = space_for_name_and_tag - tag_len - 1
        if utf8_len(name) > name_budget then
          name = utf8_sub(name, name_budget - 1) .. "…"
        end
        include_tag = true
      else
        -- Not enough for tag; use all space for name (priority: name > tag)
        if utf8_len(name) > space_for_name_and_tag then
          name = utf8_sub(name, space_for_name_and_tag - 1) .. "…"
        end
        include_tag = false
      end
    else
      -- No space for name; degenerate case (glyph alone may not fit)
      name = ""
      include_tag = false
    end

    table.insert(spans, { hl_for(node, row.is_root), col, col + #name })

    -- Build text with deliberate truncation
    text = gutter .. glyph .. " " .. name
    if include_tag then
      text = text .. " " .. tag
      -- Span for tag only if included
      table.insert(spans, { "DbtForgeLineageMaterialization", #(gutter .. glyph .. " " .. name .. " "), #(gutter .. glyph .. " " .. name .. " " .. tag) })
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
