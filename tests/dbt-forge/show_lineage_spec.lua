-- Covers dbt-forge.show_lineage's handling of a buffer that lives outside
-- the configured dbt project. Uses the REAL dbt-forge.utils (not mocked),
-- so utils.rel_path's own "not inside the project" logic is exercised
-- end-to-end rather than just show_lineage's handling of a stubbed nil.

describe("dbt-forge.show_lineage", function()
  local dbt_forge
  local notifications
  local original_notify, original_expand

  before_each(function()
    notifications = {}

    package.loaded["dbt-forge.manifest"] = {
      load = function()
        return { by_name = {} }
      end,
      resolve = function()
        error("manifest.resolve must not be called for a buffer outside the project")
      end,
    }
    package.loaded["dbt-forge.lineage_view"] = {
      open = function()
        error("lineage_view.open must not be called for a buffer outside the project")
      end,
    }

    package.loaded["dbt-forge"] = nil
    dbt_forge = require("dbt-forge")

    local config = require("dbt-forge.config")
    config.options = {
      dbt_project_path = "/p/proj",
      lineage = { include = { "model" } },
    }

    original_expand = vim.fn.expand
    vim.fn.expand = function(fmt)
      if fmt == "%:e" then
        return "sql"
      elseif fmt == "%:p" then
        return "/tmp/outside/fct_orders.sql"
      elseif fmt == "%:t:r" then
        return "fct_orders"
      end
      return ""
    end

    original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notifications, { msg = msg, level = level })
    end
  end)

  after_each(function()
    package.loaded["dbt-forge.manifest"] = nil
    package.loaded["dbt-forge.lineage_view"] = nil
    package.loaded["dbt-forge"] = nil
    vim.fn.expand = original_expand
    vim.notify = original_notify
  end)

  it("routes a buffer outside the project to the existing not-in-manifest warning", function()
    local ok = pcall(dbt_forge.show_lineage)

    assert.is_true(ok)
    assert.are.equal(1, #notifications)
    assert.are.equal(vim.log.levels.WARN, notifications[1].level)
    assert.is_truthy(notifications[1].msg:find("not in manifest", 1, true))
  end)
end)
