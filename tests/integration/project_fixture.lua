-- Fabricates a throwaway dbt project on disk -- dbt_project.yml, model files
-- and a manifest.json describing a diamond through an ephemeral model, with a
-- test node and a source included so filtering and source naming are covered.
-- Returns the project root. Shared by the split and float end-to-end passes so
-- the manifest literal lives in exactly one place.
return function()
  -- Build a throwaway dbt project: dbt_project.yml, two model files, and a
  -- manifest.json describing a diamond through an ephemeral model.
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/models/marts", "p")
  vim.fn.mkdir(root .. "/models/staging", "p")
  vim.fn.mkdir(root .. "/target", "p")

  vim.fn.writefile({ "name: jaffle_shop", "version: '1.0'" }, root .. "/dbt_project.yml")
  vim.fn.writefile({ "select 1 as order_id" }, root .. "/models/marts/fct_orders.sql")
  vim.fn.writefile({ "select 1 as order_id" }, root .. "/models/staging/stg_orders.sql")
  vim.fn.writefile({ "select 1 as customer_id" }, root .. "/models/marts/dim_customers.sql")

  local manifest = {
    metadata = { project_name = "jaffle_shop" },
    nodes = {
      ["model.jaffle_shop.stg_orders"] = {
        name = "stg_orders", resource_type = "model", package_name = "jaffle_shop",
        original_file_path = "models/staging/stg_orders.sql",
        config = { materialized = "view" },
      },
      ["model.jaffle_shop.int_pivot"] = {
        name = "int_pivot", resource_type = "model", package_name = "jaffle_shop",
        original_file_path = "models/staging/int_pivot.sql",
        config = { materialized = "ephemeral" },
      },
      ["model.jaffle_shop.fct_orders"] = {
        name = "fct_orders", resource_type = "model", package_name = "jaffle_shop",
        original_file_path = "models/marts/fct_orders.sql",
        config = { materialized = "table" },
      },
      ["model.jaffle_shop.dim_customers"] = {
        name = "dim_customers", resource_type = "model", package_name = "jaffle_shop",
        original_file_path = "models/marts/dim_customers.sql",
        config = { materialized = "table" },
      },
      ["test.jaffle_shop.unique_order_id.abc"] = {
        name = "unique_order_id", resource_type = "test", package_name = "jaffle_shop",
        original_file_path = "models/marts/schema.yml", config = {},
      },
    },
    sources = {
      ["source.jaffle_shop.jaffle.orders"] = {
        name = "orders", source_name = "jaffle", resource_type = "source",
        package_name = "jaffle_shop", original_file_path = "models/staging/sources.yml",
      },
    },
    exposures = {},
    parent_map = {
      ["source.jaffle_shop.jaffle.orders"] = {},
      ["model.jaffle_shop.stg_orders"] = { "source.jaffle_shop.jaffle.orders" },
      ["model.jaffle_shop.int_pivot"] = { "model.jaffle_shop.stg_orders" },
      ["model.jaffle_shop.fct_orders"] = {
        "model.jaffle_shop.stg_orders", "model.jaffle_shop.int_pivot",
      },
      ["model.jaffle_shop.dim_customers"] = { "model.jaffle_shop.fct_orders" },
      ["test.jaffle_shop.unique_order_id.abc"] = { "model.jaffle_shop.fct_orders" },
    },
    child_map = {
      ["source.jaffle_shop.jaffle.orders"] = { "model.jaffle_shop.stg_orders" },
      ["model.jaffle_shop.stg_orders"] = {
        "model.jaffle_shop.fct_orders", "model.jaffle_shop.int_pivot",
      },
      ["model.jaffle_shop.int_pivot"] = { "model.jaffle_shop.fct_orders" },
      ["model.jaffle_shop.fct_orders"] = {
        "model.jaffle_shop.dim_customers", "test.jaffle_shop.unique_order_id.abc",
      },
      ["model.jaffle_shop.dim_customers"] = {},
    },
  }

  vim.fn.writefile({ vim.json.encode(manifest) }, root .. "/target/manifest.json")

  return root
end
