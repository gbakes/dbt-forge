local M = {}

local config = require("dbt-forge.config")
local manifest = require("dbt-forge.manifest")
local lineage = require("dbt-forge.lineage")
local render = require("dbt-forge.render")

local ns = vim.api.nvim_create_namespace("dbt-forge-lineage")

-- Linked to stock groups so every colorscheme gets sensible output for free.
local HIGHLIGHTS = {
  DbtForgeLineageRail = "Comment",
  DbtForgeLineageNode = "Normal",
  DbtForgeLineageRoot = "Title",
  DbtForgeLineageSource = "Constant",
  DbtForgeLineageMaterialization = "Comment",
  DbtForgeLineageHeader = "Statement",
  DbtForgeLineageStale = "WarningMsg",
}

-- Ephemeral is the one group that needs an attribute of its own, and a link
-- cannot carry one: `nvim_set_hl` resolves a linked group to the target's
-- attributes ALONE, so an `italic` passed alongside `link` never reaches the
-- screen. (Worse, passing it as a second `default = true` call is a plain
-- no-op, because the loop above has already defined the group.) So derive
-- Special's resolved attributes and add italic to them.
--
-- That costs the link's automatic colorscheme tracking, hence the hook below.
-- A user overriding this group should do it from a ColorScheme autocmd of
-- their own, since a plain `:highlight` would be re-derived out from under
-- them on the next colorscheme change.
local function derive_ephemeral()
  local special = vim.api.nvim_get_hl(0, { name = "Special", link = false })
  vim.api.nvim_set_hl(
    0,
    "DbtForgeLineageEphemeral",
    vim.tbl_extend("force", special, { italic = true })
  )
end

local function ensure_highlights()
  for group, link in pairs(HIGHLIGHTS) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
  derive_ephemeral()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("DbtForgeLineageHighlights", { clear = true }),
    callback = derive_ephemeral,
    desc = "Re-derive the ephemeral lineage highlight from the new colorscheme",
  })
end

-- Sidebar state. `win`/`buf` are nil when closed. `up`/`down` deliberately
-- survive `close()` (they are only reset to the configured defaults the
-- first time `open()` ever runs) so re-opening the sidebar restores whatever
-- depth the user last dialed in with +/- rather than snapping back to the
-- config defaults — this is intentional, not a missed reset.
local state = {
  win = nil,
  buf = nil,
  root_id = nil,
  up = nil,
  down = nil,
  line_to_node = {},
}

local function reset_state()
  state.win, state.buf = nil, nil
  state.line_to_node = {}
end

-- `win` alone can be a stale signal: `:bd` on the sidebar buffer leaves the
-- window in place (Neovim swaps in a fresh scratch buffer) but wipes our
-- buffer out from under us, so `state.buf` becomes a dangling handle. Treat
-- the sidebar as open only when the window is still showing the buffer we
-- created.
function M.is_open()
  return state.win ~= nil
    and vim.api.nvim_win_is_valid(state.win)
    and state.buf ~= nil
    and vim.api.nvim_buf_is_valid(state.buf)
    and vim.api.nvim_win_get_buf(state.win) == state.buf
end

-- Belt-and-suspenders: proactively clear state the moment the sidebar's
-- window or buffer disappears by any means (`:bd`, `:close`, `<C-w>c`, ...),
-- so a stale handle can never survive into a later `rerender()`. `is_open()`
-- above is already correct without this, but this keeps `state` honest
-- immediately rather than only on the next check.
local function watch_for_staleness(win, buf)
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      if state.win == win then
        reset_state()
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      if state.buf == buf then
        reset_state()
      end
    end,
  })
end

local function is_float()
  return config.options.lineage.presentation == "float"
end

-- Geometry for the floating presentation, centred on the editor.
--
-- `nvim_open_win`'s width/height exclude the border, so a border costs two
-- columns and two rows on top of whatever is asked for. Subtracting that up
-- front is what lets width_ratio = 1.0 mean "as wide as Neovim" instead of
-- overflowing the editor by two columns. `lines - 2` leaves the command line
-- and the global statusline alone.
local function float_geometry()
  local opts = config.options.lineage.float
  local border = opts.border or config.options.ui.float_border
  local frame = (border and border ~= "none") and 2 or 0

  local avail_w, avail_h = vim.o.columns, vim.o.lines - 2
  local width = math.max(1, math.floor(avail_w * opts.width_ratio) - frame)
  local height = math.max(1, math.floor(avail_h * opts.height_ratio) - frame)

  return {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((avail_h - (height + frame)) / 2)),
    col = math.max(0, math.floor((avail_w - (width + frame)) / 2)),
    border = border,
  }
end

local function age_label(mtime)
  local seconds = os.time() - mtime
  if seconds < 90 then
    return string.format("%ds old", seconds)
  elseif seconds < 5400 then
    return string.format("%dm old", math.floor(seconds / 60))
  end
  return string.format("%dh old", math.floor(seconds / 3600))
end

-- How wide to lay the rows out. The split is a fixed column count, so it
-- lays out to exactly that. A float is usually wider than the graph needs,
-- and laying out to the window would right-align every materialization tag
-- against the far edge, so it lays out to whichever is smaller.
local function layout_width(graph, rows)
  if not is_float() then
    return config.options.lineage.width
  end
  return math.min(vim.api.nvim_win_get_width(state.win), render.natural_width(graph, rows))
end

local function draw(graph, sub, rows)
  local width = layout_width(graph, rows)
  local lines, all_spans = {}, {}
  state.line_to_node = {}

  for i, row in ipairs(rows) do
    local text, spans = render.format(graph, row, width)
    lines[i] = text
    all_spans[i] = spans
    if row.kind == "node" then
      state.line_to_node[i] = row.id
    end
  end

  vim.api.nvim_buf_set_option(state.buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)

  for lnum, spans in pairs(all_spans) do
    for _, span in ipairs(spans) do
      local hl_group, start_col, end_col = span[1], span[2], span[3]
      local ok = pcall(vim.api.nvim_buf_set_extmark, state.buf, ns, lnum - 1, start_col, {
        end_col = end_col,
        hl_group = hl_group,
      })
      if not ok then
        vim.notify(
          string.format(
            "dbt-forge: rejected extmark at line %d cols %d-%d — please report this",
            lnum, start_col, end_col
          ),
          vim.log.levels.WARN
        )
      end
    end
  end

  vim.api.nvim_buf_set_option(state.buf, "modifiable", false)

  local node_count = 0
  for _ in pairs(sub.depth) do
    node_count = node_count + 1
  end

  vim.wo[state.win].winbar = string.format(
    "%s · ↑%d ↓%d · %d nodes · manifest %s",
    graph.nodes[state.root_id].name,
    state.up,
    state.down,
    node_count,
    age_label(graph.mtime or os.time())
  )
end

-- Rebuilds the graph for the current root/depth and repaints. Safe to call
-- repeatedly: the manifest is cached on mtime, so this is a few milliseconds.
local function rerender()
  local graph, err = manifest.load(
    config.options.dbt_project_path,
    config.options.lineage.include
  )
  if not graph then
    vim.notify("dbt-forge: " .. err, vim.log.levels.ERROR)
    return
  end
  if not graph.nodes[state.root_id] then
    vim.notify(
      "dbt-forge: model not in manifest — press R to run dbt parse",
      vim.log.levels.WARN
    )
    return
  end
  local lane_rows, sub = lineage.build(graph, state.root_id, state.up, state.down)
  draw(graph, sub, render.rail_rows(graph, lane_rows, state.root_id))
end

local function node_under_cursor()
  local lnum = vim.api.nvim_win_get_cursor(state.win)[1]
  return state.line_to_node[lnum]
end

-- Finds the window files should open into: the sidebar's "previous" window.
-- If the sidebar is the only window in the tabpage (`<C-w>o` from inside it,
-- or every other split got closed), `wincmd p` has no previous window to
-- return to and raises an error — and even when it doesn't error, it can
-- leave us right back on the sidebar itself. Either way, never edit a file
-- into the sidebar buffer: fall back to opening a fresh split to its right.
local function target_window()
  local ok = pcall(vim.cmd, "wincmd p")
  local win = vim.api.nvim_get_current_win()
  if ok and win ~= state.win then
    return win
  end
  -- Fallback: `vsplit` runs with the sidebar itself as the current window,
  -- so it halves the SIDEBAR's own column rather than carving a window out
  -- of already-more-than-48-columns of free space — `winfixwidth` guards
  -- against other windows' resizing, not against a literal split of the
  -- fixed window itself. Restore the sidebar to its configured width now
  -- that the new editing window exists, before anything else can read or
  -- rely on it.
  vim.cmd("belowright vsplit")
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_set_width(state.win, config.options.lineage.width)
  end
  return vim.api.nvim_get_current_win()
end

-- One-shot flag consumed by follow (dbt-forge._follow_current_buffer). A
-- keep-focus open (`o`) covers it across its ENTIRE open sequence, not just
-- the `:edit`: `target_window()` below runs `wincmd p` (or the vsplit
-- fallback), which itself fires a real BufEnter for whatever buffer that
-- window already held — BEFORE the intended file is opened. Suppressing
-- only around `:edit` (as an earlier version of this did) left that
-- window-switch BufEnter unsuppressed, so a peek could follow onto the
-- STALE buffer the editing window happened to be showing, not even the
-- peeked node. Re-rooting on either BufEnter during a peek would also
-- collapse `o` and `<CR>` into the same behaviour bar focus, and make
-- peeking at two sibling nodes in turn impossible (the first peek's target
-- would no longer be on screen once the sidebar re-rooted).
local suppress_follow = false

-- Consumes (reads, then clears) the suppression flag. Follow calls this as
-- the very first thing it does on every BufEnter.
function M.consume_follow_suppression()
  local was = suppress_follow
  suppress_follow = false
  return was
end

-- Suppresses follow across `switch_fn` (the window switch, which may itself
-- fire a spurious BufEnter) and `edit_fn` (the real `:edit`), then restores
-- the flag to its correct state for each. `keep_focus == true` (`o`) needs
-- BOTH BufEnters suppressed, so the flag is re-armed right after
-- `switch_fn` returns — the spurious BufEnter it triggered may already have
-- consumed (and cleared) the initial `true`, and a single "consume" cannot
-- by itself survive two separate BufEnters. `keep_focus == false` (`<CR>`)
-- wants only the window-switch BufEnter suppressed, so the flag is
-- explicitly disarmed before `edit_fn` runs, regardless of whether the
-- switch happened to consume it already.
--
-- `edit_fn` runs under `pcall`, and the flag is cleared UNCONDITIONALLY
-- right after — including when `edit_fn` throws (e.g. `:edit` hitting E37
-- on a modified buffer with `nofile` `hidden`). Without the `pcall`, a
-- thrown error unwinds straight out of this function and skips the clear
-- entirely, leaving `suppress_follow` stuck `true` and silently swallowing
-- every later, unrelated BufEnter until the next open. Returns the pcall's
-- `ok, err`.
local function with_follow_suppressed(keep_focus, switch_fn, edit_fn)
  suppress_follow = true
  switch_fn()
  suppress_follow = keep_focus
  local ok, err = pcall(edit_fn)
  suppress_follow = false
  return ok, err
end

-- Opens `path` (optionally at `line`) in the editing window, then restores
-- focus to the sidebar when `keep_focus` is set. Reports (rather than
-- crashing on) a failed `:edit` — e.g. E37 on a modified buffer — so a
-- failed peek is never silent.
-- Gets us to the window the file should open into. For a float that is about
-- to be dismissed, closing it IS the switch: Neovim hands focus back to the
-- window underneath, so there is no `wincmd p` dance and no vsplit fallback
-- to get wrong. A kept-focus peek (`o`) has to leave the float up, so it
-- takes the normal path.
local function switch_to_editing_window(keep_focus)
  if is_float() and not keep_focus then
    M.close()
    return
  end
  vim.api.nvim_set_current_win(target_window())
end

local function open_in_previous(path, line, keep_focus)
  local ok, err = with_follow_suppressed(
    keep_focus,
    function() switch_to_editing_window(keep_focus) end,
    function() vim.cmd("edit " .. vim.fn.fnameescape(path)) end
  )
  if not ok then
    vim.notify("dbt-forge: could not open " .. path .. ": " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  if line then
    vim.api.nvim_win_set_cursor(0, { line, 0 })
  end
  if keep_focus then
    vim.api.nvim_set_current_win(state.win)
  end
end

local function open_node(keep_focus)
  local node_id = node_under_cursor()
  if not node_id then
    return
  end

  local graph, err = manifest.load(
    config.options.dbt_project_path,
    config.options.lineage.include
  )
  if not graph then
    vim.notify("dbt-forge: " .. err, vim.log.levels.ERROR)
    return
  end
  local node = graph.nodes[node_id]

  -- Sources live inside a yml alongside other tables, so jump to the table
  -- definition rather than line 1.
  if node.resource_type == "source" then
    local namespace, table_name = node.name:match("^([^.]+)%.(.+)$")
    local ok, target = pcall(require("dbt-forge.goto").resolve_source, namespace, table_name)
    if ok and target then
      open_in_previous(target.file, target.line, keep_focus)
      return
    end
  end

  open_in_previous(config.options.dbt_project_path .. "/" .. node.path, nil, keep_focus)
end

local function set_depth(delta)
  state.up = math.max(0, state.up + delta)
  state.down = math.max(0, state.down + delta)
  rerender()
end

local function reroot()
  local node_id = node_under_cursor()
  if not node_id then
    return
  end
  state.root_id = node_id
  rerender()
end

local function refresh()
  local utils = require("dbt-forge.utils")
  local loading = require("dbt-forge.loading")
  loading.show_loading("dbt parse")
  vim.fn.jobstart(utils.build_dbt_command("dbt parse"), {
    on_exit = function(_, code)
      loading.hide_loading()
      if code ~= 0 then
        vim.notify("dbt-forge: dbt parse failed", vim.log.levels.ERROR)
        return
      end
      manifest.invalidate()
      if M.is_open() then
        rerender()
      end
    end,
  })
end

local function set_keymaps()
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, {
      buffer = state.buf, nowait = true, silent = true, desc = desc,
    })
  end
  map("<CR>", function() open_node(false) end, "Open model")
  map("o", function() open_node(true) end, "Open model, keep focus")
  map("r", reroot, "Re-root lineage here")
  map("+", function() set_depth(1) end, "Widen lineage depth")
  map("-", function() set_depth(-1) end, "Narrow lineage depth")
  map("R", refresh, "Run dbt parse and reload")
  map("q", M.close, "Close lineage")
  map("<ESC>", M.close, "Close lineage")
end

function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  reset_state()
end

-- Re-roots an already-open sidebar without stealing focus. Used by follow.
function M.refocus(node_id)
  if not M.is_open() then
    return
  end
  state.root_id = node_id
  rerender()
end

function M.open(root_id)
  ensure_highlights()

  state.root_id = root_id
  state.up = state.up or config.options.lineage.up_depth
  state.down = state.down or config.options.lineage.down_depth

  if M.is_open() then
    rerender()
    return
  end

  local previous = vim.api.nvim_get_current_win()

  state.buf = vim.api.nvim_create_buf(false, true)
  if is_float() then
    state.win = vim.api.nvim_open_win(state.buf, true, float_geometry())
  else
    vim.cmd("topleft vsplit")
    state.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(state.win, config.options.lineage.width)
    vim.api.nvim_win_set_buf(state.win, state.buf)
  end
  watch_for_staleness(state.win, state.buf)

  vim.api.nvim_buf_set_option(state.buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(state.buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(state.buf, "swapfile", false)
  vim.api.nvim_buf_set_option(state.buf, "filetype", "dbtlineage")
  vim.api.nvim_win_set_option(state.win, "wrap", false)
  vim.api.nvim_win_set_option(state.win, "number", false)
  vim.api.nvim_win_set_option(state.win, "relativenumber", false)
  vim.api.nvim_win_set_option(state.win, "cursorline", true)
  if not is_float() then
    -- Only meaningful for a real split; a float has no neighbours to be
    -- resized by.
    vim.api.nvim_win_set_option(state.win, "winfixwidth", true)
  end
  vim.api.nvim_win_set_option(state.win, "signcolumn", "no")

  set_keymaps()
  rerender()

  -- `wincmd p` in open_node relies on the editing window being the previous
  -- one, so hand focus back and forth explicitly here.
  vim.api.nvim_set_current_win(previous)
  vim.api.nvim_set_current_win(state.win)
end

-- Exposed for testing. `with_follow_suppressed` takes plain callables for
-- its window-switch/edit steps rather than calling vim.api/vim.cmd
-- directly, so its choreography (arm before switch, re-arm-or-disarm
-- before edit depending on keep_focus, unconditional clear afterwards even
-- on a thrown error) is exercisable under busted without a vim.api stub.
M._with_follow_suppressed = with_follow_suppressed

return M
