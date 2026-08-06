-- Mirrors the shape of a real dbt manifest.json (schema v12), trimmed to the
-- keys dbt-forge reads. Returns a *function* so each spec gets a fresh table
-- and cannot leak mutations into its neighbours.
return function()
  return {
    metadata = {
      project_name = "jaffle_shop",
      dbt_schema_version = "https://schemas.getdbt.com/dbt/manifest/v12.json",
    },
    nodes = {
      ["model.jaffle_shop.stg_orders"] = {
        name = "stg_orders", resource_type = "model", package_name = "jaffle_shop",
        original_file_path = "models/staging/stg_orders.sql",
        config = { materialized = "view" },
      },
      ["model.jaffle_shop.stg_payments"] = {
        name = "stg_payments", resource_type = "model", package_name = "jaffle_shop",
        original_file_path = "models/staging/stg_payments.sql",
        config = { materialized = "view" },
      },
      ["model.jaffle_shop.int_payments_pivoted"] = {
        name = "int_payments_pivoted", resource_type = "model", package_name = "jaffle_shop",
        original_file_path = "models/intermediate/int_payments_pivoted.sql",
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
      -- No `config.materialized`: must default to "view".
      ["model.jaffle_shop.legacy_orders"] = {
        name = "legacy_orders", resource_type = "model", package_name = "jaffle_shop",
        original_file_path = "models/legacy/legacy_orders.sql",
        config = {},
      },
      -- Must never appear in the projected graph.
      ["test.jaffle_shop.unique_fct_orders_order_id.abc123"] = {
        name = "unique_fct_orders_order_id", resource_type = "test",
        package_name = "jaffle_shop",
        original_file_path = "models/marts/schema.yml",
        config = { materialized = "test" },
      },
    },
    sources = {
      ["source.jaffle_shop.jaffle.orders"] = {
        name = "orders", source_name = "jaffle", resource_type = "source",
        package_name = "jaffle_shop", original_file_path = "models/staging/sources.yml",
      },
      ["source.jaffle_shop.stripe.payments"] = {
        name = "payments", source_name = "stripe", resource_type = "source",
        package_name = "jaffle_shop", original_file_path = "models/staging/sources.yml",
      },
    },
    exposures = {},
    -- Must never appear.
    macros = {
      ["macro.dbt.test_unique"] = { name = "test_unique", resource_type = "macro" },
    },
    parent_map = {
      ["source.jaffle_shop.jaffle.orders"] = {},
      ["source.jaffle_shop.stripe.payments"] = {},
      ["model.jaffle_shop.stg_orders"] = { "source.jaffle_shop.jaffle.orders" },
      ["model.jaffle_shop.stg_payments"] = { "source.jaffle_shop.stripe.payments" },
      ["model.jaffle_shop.int_payments_pivoted"] = { "model.jaffle_shop.stg_payments" },
      ["model.jaffle_shop.fct_orders"] = {
        "model.jaffle_shop.stg_orders", "model.jaffle_shop.int_payments_pivoted",
      },
      ["model.jaffle_shop.dim_customers"] = { "model.jaffle_shop.fct_orders" },
      ["model.jaffle_shop.legacy_orders"] = {},
      ["test.jaffle_shop.unique_fct_orders_order_id.abc123"] = { "model.jaffle_shop.fct_orders" },
    },
    child_map = {
      ["source.jaffle_shop.jaffle.orders"] = { "model.jaffle_shop.stg_orders" },
      ["source.jaffle_shop.stripe.payments"] = { "model.jaffle_shop.stg_payments" },
      ["model.jaffle_shop.stg_orders"] = { "model.jaffle_shop.fct_orders" },
      ["model.jaffle_shop.stg_payments"] = { "model.jaffle_shop.int_payments_pivoted" },
      ["model.jaffle_shop.int_payments_pivoted"] = { "model.jaffle_shop.fct_orders" },
      ["model.jaffle_shop.fct_orders"] = {
        "model.jaffle_shop.dim_customers",
        "test.jaffle_shop.unique_fct_orders_order_id.abc123",
      },
      ["model.jaffle_shop.dim_customers"] = {},
      ["model.jaffle_shop.legacy_orders"] = {},
    },
  }
end
