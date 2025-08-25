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

        it("should show error when dbt_project_path not provided", function()
            local notify_called = false
            local notify_level = nil

            vim.notify = function(msg, level)
                notify_called = true
                notify_level = level
            end

            vim.log = { levels = { ERROR = "error" } }

            config.setup()

            assert.is_true(notify_called)
            assert.are.equal("error", notify_level)
        end)
    end)
end)

