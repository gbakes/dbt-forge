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

    -- Real Neovim's tbl_deep_extend treats an EMPTY table as mergeable, so
    -- passing `keymaps = {}` leaves the defaults intact. The stub in
    -- tests/helper.lua has to agree: if it replaced instead, every config spec
    -- here would be asserting behaviour the plugin does not actually have.
    it("keeps default keymaps when handed an empty keymaps table", function()
      config.setup({ dbt_project_path = "/test/path", keymaps = {} })
      assert.are.equal("<leader>dr", config.options.keymaps.run_model)
      assert.are.equal("<leader>dl", config.options.keymaps.lineage)
    end)

    it("still replaces a list-like table wholesale rather than merging by index", function()
      -- The other half of the same rule, and the reason the stub cannot simply
      -- merge everything: a narrowed include list must not keep the defaults'
      -- trailing entries.
      config.setup({ dbt_project_path = "/test/path", lineage = { include = { "model" } } })
      assert.are.same({ "model" }, config.options.lineage.include)
    end)

    it("presents as a split by default", function()
      config.setup({ dbt_project_path = "/test/path" })
      assert.are.equal("split", config.options.lineage.presentation)
    end)

    it("defaults the float to most of the editor, not all of it", function()
      config.setup({ dbt_project_path = "/test/path" })
      assert.are.equal(0.9, config.options.lineage.float.width_ratio)
      assert.are.equal(0.8, config.options.lineage.float.height_ratio)
    end)

    it("lets the user ask for a float as wide as the editor", function()
      config.setup({
        dbt_project_path = "/test/path",
        lineage = { presentation = "float", float = { width_ratio = 1.0 } },
      })
      assert.are.equal("float", config.options.lineage.presentation)
      assert.are.equal(1.0, config.options.lineage.float.width_ratio)
      -- The untouched ratio must survive the merge rather than going nil.
      assert.are.equal(0.8, config.options.lineage.float.height_ratio)
    end)

    it("lets the user narrow the include list to specific resource types", function()
      config.setup({ dbt_project_path = "/test/path", lineage = { include = { "model" } } })
      assert.are.same({ "model" }, config.options.lineage.include)
    end)
  end)
end)

