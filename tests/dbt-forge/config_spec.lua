local config = require("dbt-forge.config")

describe("config", function()
    before_each(function()
        config.options = {}
    end)

    describe("setup", function()
        it("should merge user options with defaults", function()
            config.setup({
                dbt_project_path = "/custom/path",
                keymaps = {
                    run_model = "<leader>cr",
                },
            })

            assert.are.equal("/custom/path", config.options.dbt_project_path)
            assert.are.equal("<leader>cr", config.options.keymaps.run_model)
            assert.are.equal("<leader>dt", config.options.keymaps.transpile_model) -- default preserved
            assert.are.equal("pyenv", config.options.python_env_manager) -- default preserved
        end)

        it("should use defaults when no options provided", function()
            config.setup()

            assert.are.equal("pyenv", config.options.python_env_manager)
            assert.are.equal("<leader>dr", config.options.keymaps.run_model)
            assert.are.equal(15, config.options.ui.split_size)
        end)

        it("should warn when dbt_project_path not provided", function()
            local notify_called = false
            local notify_level = nil

            vim.notify = function(msg, level)
                notify_called = true
                notify_level = level
            end

            vim.log = { levels = { ERROR = "error", WARN = "warn" } }

            config.setup()

            assert.is_true(notify_called)
            -- A missing dbt_project.yml is a warning, not an error: the
            -- plugin still loads and its other features still work.
            assert.are.equal("warn", notify_level)
        end)
    end)

  describe("lineage configuration", function()
    it("defaults to two hops in each direction", function()
      config.setup({ dbt_project_path = "/test/path" })
      assert.are.equal(2, config.options.lineage.up_depth)
      assert.are.equal(2, config.options.lineage.down_depth)
    end)

    it("defaults the sidebar width and follow behaviour", function()
      config.setup({ dbt_project_path = "/test/path" })
      assert.are.equal(48, config.options.lineage.width)
      assert.is_true(config.options.lineage.follow)
    end)

    it("includes models, sources, seeds, snapshots and exposures by default", function()
      config.setup({ dbt_project_path = "/test/path" })
      assert.are.same(
        { "model", "source", "seed", "snapshot", "exposure" },
        config.options.lineage.include
      )
    end)

    it("binds <leader>dl by default", function()
      config.setup({ dbt_project_path = "/test/path" })
      assert.are.equal("<leader>dl", config.options.keymaps.lineage)
    end)

    it("lets the user override depth without losing other defaults", function()
      config.setup({ dbt_project_path = "/test/path", lineage = { up_depth = 5 } })
      assert.are.equal(5, config.options.lineage.up_depth)
      assert.are.equal(2, config.options.lineage.down_depth)
      assert.are.equal(48, config.options.lineage.width)
    end)
  end)
end)

