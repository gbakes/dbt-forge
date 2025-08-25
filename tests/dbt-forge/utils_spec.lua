local utils = require("dbt-forge.utils")
local config = require("dbt-forge.config")

describe("utils", function()
    before_each(function()
        config.setup({
            dbt_project_path = "/test/path",
            python_env_manager = "pyenv",
            python_env_name = "test-env",
        })
    end)

    describe("is_sql_file", function()
        it("should return true for SQL files", function()
            vim.fn = vim.fn or {}
            vim.fn.expand = function(arg)
                if arg == "%:e" then
                    return "sql"
                end
                return ""
            end

            assert.is_true(utils.is_sql_file())
        end)

        it("should return false for non-SQL files", function()
            vim.fn = vim.fn or {}
            vim.fn.expand = function(arg)
                if arg == "%:e" then
                    return "py"
                end
                return ""
            end

            assert.is_false(utils.is_sql_file())
        end)
    end)

    describe("build_dbt_command", function()
        it("should build command with pyenv", function()
            local result = utils.build_dbt_command("dbt run")
            local expected = 'cd /test/path && eval "$(pyenv init -)" && pyenv activate test-env && dbt run'
            assert.are.equal(expected, result)
        end)

        it("should build command without env manager", function()
            config.setup({
                dbt_project_path = "/test/path",
                python_env_manager = "none",
            })

            local result = utils.build_dbt_command("dbt run")
            local expected = "cd /test/path && dbt run"
            assert.are.equal(expected, result)
        end)

        it("should build command with conda", function()
            config.setup({
                dbt_project_path = "/test/path",
                python_env_manager = "conda",
                python_env_name = "test-env",
            })

            local result = utils.build_dbt_command("dbt run")
            local expected = "cd /test/path && conda activate test-env && dbt run"
            assert.are.equal(expected, result)
        end)
    end)
end)

