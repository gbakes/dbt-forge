-- Drives dbt-forge._follow_current_buffer() directly (the seam extracted
-- from the BufEnter autocmd body), with lineage_view and manifest swapped
-- out via package.loaded so the follow logic can be exercised without a
-- real sidebar or a real manifest.json.

describe("dbt-forge._follow_current_buffer", function()
  local dbt_forge
  local view_calls, manifest_calls
  local original_notify, original_expand

  before_each(function()
    view_calls = { refocus = {} }
    manifest_calls = { load = 0, graph = nil, err = nil, resolved_id = nil }

    package.loaded["dbt-forge.lineage_view"] = {
      is_open = function()
        return true
      end,
      refocus = function(node_id)
        table.insert(view_calls.refocus, node_id)
      end,
    }

    package.loaded["dbt-forge.manifest"] = {
      load = function(project_path, include)
        manifest_calls.load = manifest_calls.load + 1
        manifest_calls.load_args = { project_path = project_path, include = include }
        return manifest_calls.graph, manifest_calls.err
      end,
      resolve = function(graph, name, rel_path)
        manifest_calls.resolve_args = { graph = graph, name = name, rel_path = rel_path }
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
    assert.are.equal(0, #view_calls.refocus)
  end)

  it("does not refocus, and raises nothing, when manifest.load fails", function()
    manifest_calls.graph, manifest_calls.err = nil, "No target/manifest.json"

    local ok = pcall(dbt_forge._follow_current_buffer)

    assert.is_true(ok)
    assert.are.equal(1, manifest_calls.load)
    assert.are.equal(0, #view_calls.refocus)
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
    assert.are.equal(0, #view_calls.refocus)
    assert.is_false(notified)
  end)

  it("calls refocus exactly once with the resolved node id", function()
    manifest_calls.graph = { by_name = {} }
    manifest_calls.resolved_id = "model.jaffle_shop.fct_orders"

    dbt_forge._follow_current_buffer()

    assert.are.same({ "model.jaffle_shop.fct_orders" }, view_calls.refocus)
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
end)
