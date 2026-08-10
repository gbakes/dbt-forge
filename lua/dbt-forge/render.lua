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
  if row.kind == "blank" then
    return "", {}
  end
  if row.kind == "header" then
    return row.text, { { "DbtForgeLineageHeader", 0, #row.text } }
  end
  if row.kind == "connector" then
    return row.gutter, { { "DbtForgeLineageRail", 0, #row.gutter } }
  end

  local node = graph.nodes[row.id]
  local gutter = row.gutter or ""
  local glyph = row.is_root and ROOT_GLYPH or NODE_GLYPH

  local spans = {}
  local col = 0
  if #gutter > 0 then
    table.insert(spans, { "DbtForgeLineageRail", 0, #gutter })
    col = #gutter
  end

  table.insert(spans, { hl_for(node, row.is_root), col, col + #glyph })
  col = col + #glyph + 1

  -- Reserve room for " " .. materialization on the right, but never let the
  -- name shrink below something readable.
  local tag = node.materialized
  local used = utf8_len(gutter) + utf8_len(glyph) + 1
  local name_budget = math.max(8, width - used - utf8_len(tag) - 1)

  local name = node.name
  if utf8_len(name) > name_budget then
    name = utf8_sub(name, name_budget - 1) .. "…"
  end

  table.insert(spans, { hl_for(node, row.is_root), col, col + #name })

  local text = gutter .. glyph .. " " .. name
  local pad = width - utf8_len(text) - utf8_len(tag)
  if pad < 1 then
    pad = 1
  end
  local tag_col = #text + pad
  text = text .. string.rep(" ", pad) .. tag
  table.insert(spans, { "DbtForgeLineageMaterialization", tag_col, tag_col + #tag })

  return text, spans
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
