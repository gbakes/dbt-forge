-- Drives dbt-forge._follow_current_buffer() directly (the seam extracted
-- from the BufEnter autocmd body), with lineage_view and manifest swapped
-- out via package.loaded so the follow logic can be exercised without a
-- real sidebar or a real manifest.json.
--
-- The manifest.resolve mock deliberately mirrors the real function's first
-- line (`local ids = graph.by_name[name]`): if `_follow_current_buffer`
-- ever called resolve() with a nil graph, this mock throws exactly like
-- production would, out of a BufEnter autocmd. That is what makes the
-- "manifest.load fails" spec below mutation-proof against a deleted
-- `if not graph then return end` guard, instead of silently tolerating nil.

describe("dbt-forge._follow_current_buffer", function()
  local dbt_forge
  local view_calls, manifest_calls
  local original_notify, original_expand

  before_each(function()
    -- `refocus_count` and `refocus_calls` (a table per call, not a plain
    -- value) are the counters the "no call" assertions rely on:
    -- `table.insert(t, nil)` is a silent no-op in Lua, so recording bare
    -- node ids in a list could never distinguish "refocus was never
    -- called" from "refocus was called with nil".
    view_calls = { refocus_count = 0, refocus_calls = {} }
    manifest_calls = { load = 0, graph = nil, err = nil, resolved_id = nil }

    package.loaded["dbt-forge.lineage_view"] = {
      is_open = function()
        return true
      end,
      consume_follow_suppression = function()
        return false
      end,
      refocus = function(node_id)
        view_calls.refocus_count = view_calls.refocus_count + 1
        table.insert(view_calls.refocus_calls, { node_id = node_id })
      end,
    }

    package.loaded["dbt-forge.manifest"] = {
      load = function(project_path, include)
        manifest_calls.load = manifest_calls.load + 1
        manifest_calls.load_args = { project_path = project_path, include = include }
        return manifest_calls.graph, manifest_calls.err
      end,
      resolve = function(graph, name, rel_path)
        manifest_calls.resolve_calls = (manifest_calls.resolve_calls or 0) + 1
        manifest_calls.resolve_args = { graph = graph, name = name, rel_path = rel_path }
        -- Faithful to manifest.resolve's real first line: indexing `nil`
        -- here throws "attempt to index a nil value", same as production.
        local _ = graph.by_name
        return manifest_calls.resolved_id
      end,
    }

    -- Force a fresh require of the module under test so it re-resolves
    -- `require("dbt-forge.config")` etc. against whatever is currently
    -- cached; the follow logic itself re-requires its collaborators on
    -- every call, so the mocks above take effect regardless.
    package.loaded["dbt-forge"] = nil
    dbt_forge = require("dbt-forge")

    local config = require("dbt-forge.config")
    config.options = {
      dbt_project_path = "/p/proj",
      lineage = { include = { "model" } },
    }

    original_expand = vim.fn.expand
    vim.fn.expand = function(fmt)
      if fmt == "%:p" then
        return "/p/proj/models/marts/fct_orders.sql"
      elseif fmt == "%:t:r" then
        return "fct_orders"
      end
      return ""
    end

    original_notify = vim.notify
  end)

  after_each(function()
    package.loaded["dbt-forge.lineage_view"] = nil
    package.loaded["dbt-forge.manifest"] = nil
    package.loaded["dbt-forge"] = nil
    vim.fn.expand = original_expand
    vim.notify = original_notify
  end)

  it("returns early and never loads the manifest when the sidebar is closed", function()
    package.loaded["dbt-forge.lineage_view"].is_open = function()
      return false
    end

    dbt_forge._follow_current_buffer()

    assert.are.equal(0, manifest_calls.load)
    assert.are.equal(0, view_calls.refocus_count)
  end)

  it("returns early, before touching the manifest, when a peek suppressed follow", function()
    package.loaded["dbt-forge.lineage_view"].consume_follow_suppression = function()
      return true
    end

    dbt_forge._follow_current_buffer()

    assert.are.equal(0, manifest_calls.load)
    assert.are.equal(0, view_calls.refocus_count)
  end)

  it("proceeds normally (e.g. after <CR>) when follow was not suppressed", function()
    package.loaded["dbt-forge.lineage_view"].consume_follow_suppression = function()
      return false
    end
    manifest_calls.graph = { by_name = {} }
    manifest_calls.resolved_id = "model.jaffle_shop.fct_orders"

    dbt_forge._follow_current_buffer()

    assert.are.equal(1, view_calls.refocus_count)
    assert.are.equal("model.jaffle_shop.fct_orders", view_calls.refocus_calls[1].node_id)
  end)

  it("does not refocus, and raises nothing, when manifest.load fails", function()
    manifest_calls.graph, manifest_calls.err = nil, "No target/manifest.json"

    local ok = pcall(dbt_forge._follow_current_buffer)

    assert.is_true(ok)
    assert.are.equal(1, manifest_calls.load)
    assert.are.equal(0, view_calls.refocus_count)
  end)

  it("does not call resolve, notify, or error for a buffer outside the project", function()
    manifest_calls.graph = { by_name = {} }
    vim.fn.expand = function(fmt)
      if fmt == "%:p" then
        return "/tmp/outside/fct_orders.sql"
      elseif fmt == "%:t:r" then
        return "fct_orders"
      end
      return ""
    end

    local notified = false
    vim.notify = function()
      notified = true
    end

    local ok = pcall(dbt_forge._follow_current_buffer)

    assert.is_true(ok)
    assert.is_nil(manifest_calls.resolve_calls)
    assert.are.equal(0, view_calls.refocus_count)
    assert.is_false(notified)
  end)

  it("does not refocus, notify, or error when the buffer is not a known model", function()
    manifest_calls.graph = { by_name = {} }
    manifest_calls.resolved_id = nil

    local notified = false
    vim.notify = function()
      notified = true
    end

    local ok = pcall(dbt_forge._follow_current_buffer)

    assert.is_true(ok)
    assert.are.equal(0, view_calls.refocus_count)
    assert.is_false(notified)
  end)

  it("calls refocus exactly once with the resolved node id", function()
    manifest_calls.graph = { by_name = {} }
    manifest_calls.resolved_id = "model.jaffle_shop.fct_orders"

    dbt_forge._follow_current_buffer()

    assert.are.equal(1, view_calls.refocus_count)
    assert.are.equal("model.jaffle_shop.fct_orders", view_calls.refocus_calls[1].node_id)
  end)

  it("resolves against the buffer path made relative to dbt_project_path", function()
    manifest_calls.graph = { by_name = {} }
    manifest_calls.resolved_id = "model.jaffle_shop.fct_orders"

    dbt_forge._follow_current_buffer()

    assert.are.equal(
      "models/marts/fct_orders.sql",
      manifest_calls.resolve_args.rel_path
    )
  end)

  it("still resolves correctly when dbt_project_path has a trailing slash", function()
    local config = require("dbt-forge.config")
    config.options.dbt_project_path = "/p/proj/"
    manifest_calls.graph = { by_name = {} }
    manifest_calls.resolved_id = "model.jaffle_shop.fct_orders"

    dbt_forge._follow_current_buffer()

    assert.are.equal(
      "models/marts/fct_orders.sql",
      manifest_calls.resolve_args.rel_path
    )
    assert.are.equal(1, view_calls.refocus_count)
  end)
end)
