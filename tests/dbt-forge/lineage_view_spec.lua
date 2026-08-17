-- First busted coverage of dbt-forge.lineage_view. Everything else in that
-- module drives real vim.api/vim.cmd directly and is exercised via the
-- headless smoke scripts instead (see
-- .superpowers/sdd/2026-08-05-model-lineage/suppresscheck9.lua and
-- followcheck9.lua). `with_follow_suppressed`, though, takes its
-- window-switch and edit steps as plain callables rather than calling
-- vim.api/vim.cmd itself, so its choreography — the actual fix for the two
-- round-2 "o" suppression defects — is testable here directly, with only a
-- one-line stub for the single vim.api call the module makes at load time
-- (nvim_create_namespace).

vim.api = vim.api or {}
vim.api.nvim_create_namespace = vim.api.nvim_create_namespace or function()
  return 1
end

-- Force a real (non-mocked) load: other specs stub
-- package.loaded["dbt-forge.lineage_view"] and clean up after themselves,
-- but be explicit here since this file needs the actual module.
package.loaded["dbt-forge.lineage_view"] = nil
local view = require("dbt-forge.lineage_view")

describe("lineage_view._with_follow_suppressed", function()
  after_each(function()
    -- Drain any suppression a test left armed so it can't leak into the
    -- next one.
    view.consume_follow_suppression()
  end)

  -- Defect A: an earlier version only set the flag around the real `:edit`,
  -- not around the window switch that precedes it. `target_window()`'s own
  -- `wincmd p` (or vsplit fallback) fires a real BufEnter for whatever
  -- buffer the target window already held, before the peeked file is ever
  -- opened — so a keep-focus peek could re-root onto a completely
  -- unrelated, stale buffer. Both call sites below simulate exactly the
  -- two BufEnters the real open_in_previous can trigger.
  it("suppresses both the window-switch BufEnter and the edit's BufEnter when keep_focus is true (regression: Defect A)", function()
    local observed = {}
    local ok = view._with_follow_suppressed(
      true, -- `o`
      function()
        -- Simulates the window switch's own (spurious) BufEnter.
        table.insert(observed, view.consume_follow_suppression())
      end,
      function()
        -- Simulates the real :edit's BufEnter.
        table.insert(observed, view.consume_follow_suppression())
      end
    )

    assert.is_true(ok)
    assert.are.same({ true, true }, observed)
    -- Must not leak into the NEXT, unrelated BufEnter either.
    assert.is_false(view.consume_follow_suppression())
  end)

  it("suppresses only the window-switch BufEnter, not the edit's, when keep_focus is false (<CR> must still re-root)", function()
    local observed = {}
    local ok = view._with_follow_suppressed(
      false, -- `<CR>`
      function()
        table.insert(observed, view.consume_follow_suppression())
      end,
      function()
        table.insert(observed, view.consume_follow_suppression())
      end
    )

    assert.is_true(ok)
    assert.are.same({ true, false }, observed)
  end)

  -- Defect B: an earlier version called `:edit` outside any pcall, so a
  -- thrown error (e.g. real E37 "No write since last change") unwound
  -- straight past the line that cleared the flag, leaving it stuck `true`
  -- and silently swallowing every later, unrelated BufEnter.
  it("clears the suppression flag even when the edit throws, keep_focus true (regression: Defect B)", function()
    local ok, err = view._with_follow_suppressed(
      true,
      function() end,
      function() error("boom: simulated E37") end
    )

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("boom", 1, true))
    -- A later, legitimate BufEnter must NOT be swallowed by a stuck flag.
    assert.is_false(view.consume_follow_suppression())
  end)

  it("clears the suppression flag even when the edit throws, keep_focus false", function()
    local ok = view._with_follow_suppressed(
      false,
      function() end,
      function() error("boom") end
    )

    assert.is_false(ok)
    assert.is_false(view.consume_follow_suppression())
  end)

  it("on normal completion returns ok == true and clears the flag afterwards", function()
    local ok, err = view._with_follow_suppressed(true, function() end, function() end)
    assert.is_true(ok)
    assert.is_nil(err)
    -- Read exactly once: consume_follow_suppression() clears on read, so a
    -- second call here would always observe false regardless of whether
    -- the implementation actually cleared it itself.
    assert.is_false(view.consume_follow_suppression())
  end)
end)
