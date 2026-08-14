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

    describe("rel_path", function()
        it("strips the project path and leading separator", function()
            assert.are.equal(
                "models/marts/fct_orders.sql",
                utils.rel_path("/p/proj", "/p/proj/models/marts/fct_orders.sql")
            )
        end)

        it("tolerates a trailing slash on the project path", function()
            assert.are.equal(
                "models/marts/fct_orders.sql",
                utils.rel_path("/p/proj/", "/p/proj/models/marts/fct_orders.sql")
            )
        end)

        it("returns nil when the buffer lives outside the project", function()
            assert.is_nil(utils.rel_path("/p/proj", "/tmp/outside/fct_orders.sql"))
        end)

        it("returns nil for a path that merely shares a prefix with the project", function()
            -- "/p/proj-other/x.sql" must not be treated as inside "/p/proj".
            assert.is_nil(utils.rel_path("/p/proj", "/p/proj-other/x.sql"))
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

