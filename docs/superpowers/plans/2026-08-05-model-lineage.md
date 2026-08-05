# Model Lineage View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Press `<leader>dl` in a dbt model buffer to open a persistent sidebar showing a navigable vertical rail graph of everything upstream and downstream of that model.

**Architecture:** Read `target/manifest.json` (cached on mtime) and project it into a compact node/parent/child graph. A dependency-free `lineage.lua` selects a depth-bounded subgraph, topologically sorts it, and assigns rail lanes. A dependency-free `render.lua` turns rows into strings plus highlight spans. Only `lineage_view.lua` touches Neovim.

**Tech Stack:** Lua 5.1 / LuaJIT, Neovim ≥ 0.8 API, busted for tests.

**Spec:** `docs/superpowers/specs/2026-08-05-model-lineage-design.md`

## Global Constraints

- Neovim ≥ 0.8. Use `(vim.uv or vim.loop)` — the `vim.uv` alias only exists from 0.10.
- `lineage.lua` and `render.lua` MUST NOT reference `vim.*` at all. They are tested under bare `luajit` with no editor.
- `manifest.lua` may use only `vim.json`, `vim.notify`, `vim.log` and `(vim.uv or vim.loop).fs_stat`.
- Free rail lanes are represented by `false`, never `nil`. `#t` on a table with `nil` holes is undefined behaviour in Lua and this algorithm indexes by `#lanes` throughout.
- Excluded resource types: tests, unit tests, macros, metrics, semantic models, saved queries. Included: model (incl. ephemeral), source, seed, snapshot, exposure.
- Follow existing code style: `local M = {}` … `return M`, two-space indent, `vim.notify` with `vim.log.levels` for user messages.
- Commit after every task.

## Deviations from the spec

Three refinements discovered while writing this plan. All are simplifications; the spec should be treated as superseded on these points.

1. **`merges` is removed from the row struct and the algorithm.** The spec's pseudocode collects converging lanes into `merges`, but that branch is unreachable: because we check for an already-open lane before allocating, and topological order guarantees a node's lane stays open until the node is emitted, two lanes can never target the same node. Convergence is expressed as a `split` into an already-open lane.
2. **`render.lua` is its own module**, rather than a `format_row` inside `lineage_view.lua`. The spec required buffer calls out of the tested path; a separate dependency-free module is the cleanest way to get that.
3. **The test fixture is a Lua table, not a `manifest.json` file.** This removes any need to decode JSON — and therefore to stub `vim.json` — in specs. The fixture mirrors real manifest v12 shape exactly, and Task 12 verifies against a real project.

## File Structure

**Create:**

| File | Responsibility |
|---|---|
| `lua/dbt-forge/manifest.lua` | Locate, decode, cache, project `manifest.json`; resolve name → node |
| `lua/dbt-forge/lineage.lua` | `select` / `topo_sort` / `assign_lanes` / `build`. Pure. |
| `lua/dbt-forge/render.lua` | Rows → line text + highlight spans. Pure. |
| `lua/dbt-forge/lineage_view.lua` | Split window, scratch buffer, extmarks, keymaps, follow |
| `tests/helper.lua` | Minimal `vim` stub so specs run under bare luajit |
| `tests/fixtures/manifest_fixture.lua` | Hand-written manifest-shaped table |
| `tests/dbt-forge/manifest_spec.lua` | Projection rules |
| `tests/dbt-forge/lineage_spec.lua` | Selection, topo sort, lane assignment |
| `tests/dbt-forge/render_spec.lua` | Line text for tree and rail renderers |

**Modify:** `.busted`, `lua/dbt-forge/config.lua`, `lua/dbt-forge/init.lua`, `plugin/dbt-forge.lua`, `README.md`

## Shared Row Contract

Both renderers emit the same row list. This is the seam that makes Phase 2 a swap rather than a rewrite.

```lua
{ kind = "node",      id = "model.pkg.name", gutter = "├─ ", is_root = false }
{ kind = "connector", gutter = "├─┘" }              -- Phase 2 only
{ kind = "header",    text = "▲ UPSTREAM" }
{ kind = "blank" }
```

`line_to_node[lnum]` is populated only for `kind == "node"`; keymaps no-op elsewhere.

---

### Task 1: Test harness

The existing specs reference a `vim` global that is never defined, and `lua/` is not on the search path, so `busted` cannot currently run at all. Fix that first — every later task depends on a working test cycle.

**Files:**
- Create: `tests/helper.lua`
- Modify: `.busted`

**Interfaces:**
- Produces: a working `busted` command; a `vim` global stub with `vim.fn`, `vim.log.levels`, `vim.notify`, `vim.tbl_deep_extend`.

- [ ] **Step 1: Install busted**

```bash
luarocks install --local busted
export PATH="$HOME/.luarocks/bin:$PATH"
```

- [ ] **Step 2: Confirm the existing specs fail**

Run: `busted`
Expected: FAIL — `module 'dbt-forge.config' not found`, or an error indexing a nil `vim`.

- [ ] **Step 3: Write the vim stub**

Create `tests/helper.lua`:

```lua
-- Minimal `vim` stub so specs run under bare luajit via busted.
-- Only the surface the plugin actually touches is provided; individual
-- specs override these fields directly when they need richer behaviour.
_G.vim = _G.vim or {}

vim.fn = vim.fn or {}
vim.log = vim.log or { levels = { ERROR = 1, WARN = 2, INFO = 3, DEBUG = 4, TRACE = 5 } }
vim.notify = vim.notify or function() end

local function deepcopy(v)
  if type(v) ~= "table" then
    return v
  end
  local out = {}
  for k, vv in pairs(v) do
    out[k] = deepcopy(vv)
  end
  return out
end

-- Deep-copies on assignment. A shallow version would alias nested tables
-- from config.defaults into config.options, so the second setup() call in a
-- test run would see the first call's values.
vim.tbl_deep_extend = vim.tbl_deep_extend or function(_, ...)
  local out = {}
  local function merge(dst, src)
    for k, v in pairs(src) do
      if type(v) == "table" and type(dst[k]) == "table" then
        merge(dst[k], v)
      else
        dst[k] = deepcopy(v)
      end
    end
  end
  for _, t in ipairs({ ... }) do
    merge(out, t)
  end
  return out
end
```

- [ ] **Step 4: Put `lua/` on the search path and load the helper**

Replace `.busted` with:

```lua
return {
    _all = {
        lua = "luajit",
    },
    default = {
        ROOT = { "tests/" },
        pattern = "_spec",
        lpath = "lua/?.lua;lua/?/init.lua",
        helper = "tests/helper.lua",
    },
}
```

- [ ] **Step 5: Run the existing specs**

Run: `busted`
Expected: PASS — both `config_spec.lua` and `utils_spec.lua` green.

- [ ] **Step 6: Commit**

```bash
git add .busted tests/helper.lua
git commit -m "test: add vim stub and lua path so busted can run specs"
```

---

### Task 2: Manifest fixture

**Files:**
- Create: `tests/fixtures/manifest_fixture.lua`

**Interfaces:**
- Produces: `require("fixtures.manifest_fixture")()` → a fresh manifest-shaped table each call.

The graph it encodes — a diamond through an ephemeral model, plus a test node that must never appear:

```
raw.jaffle.orders  ──► stg_orders ───────────────┐
                                                 ├─► fct_orders ──► dim_customers
raw.stripe.payments ─► stg_payments ─► int_payments_pivoted (ephemeral)
                                                 ┘
                                    fct_orders also has a test child
```

- [ ] **Step 1: Write the fixture**

Create `tests/fixtures/manifest_fixture.lua`:

```lua
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
```

- [ ] **Step 2: Confirm it loads**

Run: `busted --lpath='lua/?.lua;tests/?.lua' -e 'local f = require("fixtures.manifest_fixture"); assert(f().nodes["model.jaffle_shop.fct_orders"], "fixture broken"); print("fixture ok")'`
Expected: prints `fixture ok`.

- [ ] **Step 3: Add `tests/` to the spec search path**

The fixture lives under `tests/`, so specs need it on `lpath`. Update `.busted`:

```lua
        lpath = "lua/?.lua;lua/?/init.lua;tests/?.lua",
```

- [ ] **Step 4: Commit**

```bash
git add tests/fixtures/manifest_fixture.lua .busted
git commit -m "test: add manifest fixture mirroring dbt manifest v12 shape"
```

---

### Task 3: `manifest.project()`

**Files:**
- Create: `lua/dbt-forge/manifest.lua`
- Test: `tests/dbt-forge/manifest_spec.lua`

**Interfaces:**
- Consumes: `require("fixtures.manifest_fixture")` from Task 2.
- Produces: `manifest.project(raw, include) -> graph`, where `include` is an array of resource type strings and `graph` is:
  ```lua
  {
    nodes    = { [unique_id] = { name, resource_type, materialized, path, package } },
    parents  = { [unique_id] = { unique_id, ... } },  -- sorted
    children = { [unique_id] = { unique_id, ... } },  -- sorted
    by_name  = { [raw_name] = { unique_id, ... } },   -- sorted
  }
  ```

- [ ] **Step 1: Write the failing test**

Create `tests/dbt-forge/manifest_spec.lua`:

```lua
local manifest = require("dbt-forge.manifest")
local fixture = require("fixtures.manifest_fixture")

local ALL = { "model", "source", "seed", "snapshot", "exposure" }

describe("manifest.project", function()
  local graph

  before_each(function()
    graph = manifest.project(fixture(), ALL)
  end)

  it("excludes tests from the node set", function()
    assert.is_nil(graph.nodes["test.jaffle_shop.unique_fct_orders_order_id.abc123"])
  end)

  it("excludes tests from the dependency maps", function()
    -- The raw child_map lists a test under fct_orders. Copying the maps
    -- verbatim would give every model phantom test children.
    assert.are.same(
      { "model.jaffle_shop.dim_customers" },
      graph.children["model.jaffle_shop.fct_orders"]
    )
  end)

  it("excludes macros entirely", function()
    assert.is_nil(graph.nodes["macro.dbt.test_unique"])
  end)

  it("retains ephemeral models with their materialization", function()
    local node = graph.nodes["model.jaffle_shop.int_payments_pivoted"]
    assert.is_not_nil(node)
    assert.are.equal("ephemeral", node.materialized)
  end)

  it("defaults models with no configured materialization to view", function()
    assert.are.equal("view", graph.nodes["model.jaffle_shop.legacy_orders"].materialized)
  end)

  it("names sources as source_name.name and types them as source", function()
    local node = graph.nodes["source.jaffle_shop.jaffle.orders"]
    assert.are.equal("jaffle.orders", node.name)
    assert.are.equal("source", node.materialized)
  end)

  it("carries original_file_path through as path", function()
    assert.are.equal(
      "models/marts/fct_orders.sql",
      graph.nodes["model.jaffle_shop.fct_orders"].path
    )
  end)

  it("sorts dependency lists for deterministic output", function()
    assert.are.same({
      "model.jaffle_shop.int_payments_pivoted",
      "model.jaffle_shop.stg_orders",
    }, graph.parents["model.jaffle_shop.fct_orders"])
  end)

  it("gives every retained node both map entries", function()
    for uid in pairs(graph.nodes) do
      assert.is_table(graph.parents[uid], uid .. " missing parents")
      assert.is_table(graph.children[uid], uid .. " missing children")
    end
  end)

  it("indexes nodes by raw name", function()
    assert.are.same({ "model.jaffle_shop.fct_orders" }, graph.by_name["fct_orders"])
  end)

  describe("the include list drives filtering", function()
    it("drops excluded types and any edges touching them", function()
      local models_only = manifest.project(fixture(), { "model" })
      assert.is_nil(models_only.nodes["source.jaffle_shop.jaffle.orders"])
      assert.are.same({}, models_only.parents["model.jaffle_shop.stg_orders"])
    end)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/dbt-forge/manifest_spec.lua`
Expected: FAIL — `module 'dbt-forge.manifest' not found`.

- [ ] **Step 3: Write the implementation**

Create `lua/dbt-forge/manifest.lua`:

```lua
local M = {}

local function display_name(node)
  if node.resource_type == "source" then
    return (node.source_name or "?") .. "." .. node.name
  end
  return node.name
end

local function materialization(node)
  if node.resource_type == "model" then
    -- dbt's own default when a model configures nothing.
    return (node.config and node.config.materialized) or "view"
  end
  return node.resource_type
end

-- Projects a decoded manifest into the compact graph the lineage view needs.
-- Pure: takes an already-decoded table, touches no IO and no vim API.
function M.project(raw, include)
  local allow = {}
  for _, resource_type in ipairs(include) do
    allow[resource_type] = true
  end

  local nodes, by_name = {}, {}

  local function take(collection)
    for uid, node in pairs(collection or {}) do
      if allow[node.resource_type] then
        nodes[uid] = {
          name = display_name(node),
          resource_type = node.resource_type,
          materialized = materialization(node),
          path = node.original_file_path,
          package = node.package_name,
        }
        by_name[node.name] = by_name[node.name] or {}
        table.insert(by_name[node.name], uid)
      end
    end
  end

  take(raw.nodes)
  take(raw.sources)
  take(raw.exposures)

  -- Filter both ends of every edge. parent_map/child_map contain test node
  -- ids; copying them verbatim gives every model phantom test children.
  local function filter_map(source_map)
    local out = {}
    for uid, list in pairs(source_map or {}) do
      if nodes[uid] then
        local kept = {}
        for _, other in ipairs(list) do
          if nodes[other] then
            table.insert(kept, other)
          end
        end
        table.sort(kept)
        out[uid] = kept
      end
    end
    return out
  end

  local parents = filter_map(raw.parent_map)
  local children = filter_map(raw.child_map)

  -- Guarantee every node has both entries so callers never nil-check.
  for uid in pairs(nodes) do
    parents[uid] = parents[uid] or {}
    children[uid] = children[uid] or {}
  end
  for _, ids in pairs(by_name) do
    table.sort(ids)
  end

  return { nodes = nodes, parents = parents, children = children, by_name = by_name }
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `busted tests/dbt-forge/manifest_spec.lua`
Expected: PASS — 11 successes.

- [ ] **Step 5: Commit**

```bash
git add lua/dbt-forge/manifest.lua tests/dbt-forge/manifest_spec.lua
git commit -m "feat: project dbt manifest into compact lineage graph"
```

---

### Task 4: `manifest.load()` — IO, caching, errors

**Files:**
- Modify: `lua/dbt-forge/manifest.lua`
- Test: `tests/dbt-forge/manifest_spec.lua`

**Interfaces:**
- Consumes: `manifest.project` (Task 3), `utils.read_file` (existing, `lua/dbt-forge/utils.lua:45`).
- Produces:
  - `manifest.load(project_path, include) -> graph|nil, err_string|nil` — `graph` gains an `mtime` field.
  - `manifest.invalidate()` — clears the cache, for the `R` refresh key.
  - `manifest.resolve(graph, name, rel_path) -> unique_id|nil`.

- [ ] **Step 1: Write the failing test**

Append to `tests/dbt-forge/manifest_spec.lua`:

```lua
describe("manifest.resolve", function()
  local ALL_TYPES = { "model", "source", "seed", "snapshot", "exposure" }

  it("resolves an unambiguous name", function()
    local graph = manifest.project(fixture(), ALL_TYPES)
    assert.are.equal(
      "model.jaffle_shop.fct_orders",
      manifest.resolve(graph, "fct_orders", "models/marts/fct_orders.sql")
    )
  end)

  it("disambiguates same-named models by file path", function()
    local raw = fixture()
    raw.nodes["model.other_pkg.fct_orders"] = {
      name = "fct_orders", resource_type = "model", package_name = "other_pkg",
      original_file_path = "models/other/fct_orders.sql",
      config = { materialized = "table" },
    }
    local graph = manifest.project(raw, ALL_TYPES)
    assert.are.equal(
      "model.other_pkg.fct_orders",
      manifest.resolve(graph, "fct_orders", "models/other/fct_orders.sql")
    )
  end)

  it("returns nil for an unknown name", function()
    local graph = manifest.project(fixture(), ALL_TYPES)
    assert.is_nil(manifest.resolve(graph, "no_such_model", "models/nope.sql"))
  end)
end)

describe("manifest.load", function()
  it("reports a missing manifest rather than erroring", function()
    local graph, err = manifest.load("/definitely/not/a/dbt/project", { "model" })
    assert.is_nil(graph)
    assert.is_string(err)
    assert.is_truthy(err:find("dbt parse"))
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/dbt-forge/manifest_spec.lua`
Expected: FAIL — `attempt to call field 'resolve' (a nil value)`.

- [ ] **Step 3: Extend the vim stub with `fs_stat`**

`manifest.load` needs `(vim.uv or vim.loop).fs_stat`. Add to `tests/helper.lua`, after the `vim.notify` line:

```lua
vim.loop = vim.loop or {}
-- Real fs_stat, minus the fields we do not use. Specs that need a specific
-- stat result override this.
vim.loop.fs_stat = vim.loop.fs_stat or function(path)
  local handle = io.open(path, "r")
  if not handle then
    return nil
  end
  local size = handle:seek("end")
  handle:close()
  return { size = size, mtime = { sec = 0 } }
end

vim.json = vim.json or {}
vim.json.decode = vim.json.decode or function()
  error("vim.json.decode is not stubbed; specs should use the Lua fixture instead")
end
```

- [ ] **Step 4: Write the implementation**

Add to `lua/dbt-forge/manifest.lua`, above `return M`:

```lua
local uv = vim.uv or vim.loop
local utils = require("dbt-forge.utils")

-- Decoding is the expensive step, so hold one projected graph keyed on the
-- manifest's mtime. Re-opening the sidebar on an unchanged manifest is a
-- table lookup.
local cache = { path = nil, mtime = nil, graph = nil }

local MAX_BYTES = 100 * 1024 * 1024

function M.invalidate()
  cache = { path = nil, mtime = nil, graph = nil }
end

function M.load(project_path, include)
  local path = project_path .. "/target/manifest.json"

  local stat = uv.fs_stat(path)
  if not stat then
    return nil, "No target/manifest.json — run `dbt parse`, or press R"
  end

  local mtime = stat.mtime.sec
  if cache.path == path and cache.mtime == mtime and cache.graph then
    return cache.graph
  end

  if stat.size > MAX_BYTES then
    vim.notify(
      string.format(
        "dbt-forge: manifest.json is %.0fMB — this may take a moment",
        stat.size / 1024 / 1024
      ),
      vim.log.levels.WARN
    )
  end

  local content = utils.read_file(path)
  if not content then
    return nil, "Could not read " .. path
  end

  local ok, raw = pcall(vim.json.decode, content)
  if not ok then
    -- Most likely caught mid-write by a concurrent dbt run.
    if cache.graph then
      vim.notify(
        "dbt-forge: manifest.json unreadable — using last good copy",
        vim.log.levels.WARN
      )
      return cache.graph
    end
    return nil, "Could not decode manifest.json"
  end

  local graph = M.project(raw, include)
  graph.mtime = mtime

  -- Peak memory is the decoded blob, which is many times larger than the
  -- projection. Drop the reference before returning so it can be collected.
  raw = nil
  content = nil

  cache = { path = path, mtime = mtime, graph = graph }
  return graph
end

-- Maps a buffer filename to a node, preferring an exact file-path match when
-- two packages define the same model name.
function M.resolve(graph, name, rel_path)
  local ids = graph.by_name[name]
  if not ids or #ids == 0 then
    return nil
  end
  if #ids == 1 then
    return ids[1]
  end
  for _, id in ipairs(ids) do
    if graph.nodes[id].path == rel_path then
      return id
    end
  end
  return ids[1]
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `busted tests/dbt-forge/manifest_spec.lua`
Expected: PASS — 15 successes.

- [ ] **Step 6: Commit**

```bash
git add lua/dbt-forge/manifest.lua tests/dbt-forge/manifest_spec.lua tests/helper.lua
git commit -m "feat: load and cache dbt manifest with mtime invalidation"
```

---

### Task 5: `lineage.select()` — depth-bounded induced subgraph

**Files:**
- Create: `lua/dbt-forge/lineage.lua`
- Test: `tests/dbt-forge/lineage_spec.lua`

**Interfaces:**
- Consumes: a `graph` from `manifest.project` (Task 3).
- Produces: `lineage.select(graph, root_id, up_depth, down_depth) -> sub`, where:
  ```lua
  sub = {
    depth    = { [unique_id] = signed_int },  -- negative upstream, 0 root, positive downstream
    parents  = { [unique_id] = { unique_id, ... } },  -- induced, sorted
    children = { [unique_id] = { unique_id, ... } },  -- induced, sorted
  }
  ```

**This module must not reference `vim.*`.**

- [ ] **Step 1: Write the failing test**

Create `tests/dbt-forge/lineage_spec.lua`:

```lua
local lineage = require("dbt-forge.lineage")
local manifest = require("dbt-forge.manifest")
local fixture = require("fixtures.manifest_fixture")

local ALL = { "model", "source", "seed", "snapshot", "exposure" }
local FCT = "model.jaffle_shop.fct_orders"

-- Builds a graph directly from adjacency pairs, for algorithm tests that
-- should not depend on the fixture's particular shape.
local function graph_from_edges(edges)
  local nodes, parents, children = {}, {}, {}
  local function ensure(id)
    if not nodes[id] then
      nodes[id] = { name = id, resource_type = "model", materialized = "view", path = id .. ".sql" }
      parents[id], children[id] = {}, {}
    end
  end
  for _, edge in ipairs(edges) do
    ensure(edge[1])
    ensure(edge[2])
    table.insert(children[edge[1]], edge[2])
    table.insert(parents[edge[2]], edge[1])
  end
  for _, list in pairs(children) do table.sort(list) end
  for _, list in pairs(parents) do table.sort(list) end
  return { nodes = nodes, parents = parents, children = children, by_name = {} }
end

describe("lineage.select", function()
  local graph

  before_each(function()
    graph = manifest.project(fixture(), ALL)
  end)

  it("assigns depth 0 to the root", function()
    local sub = lineage.select(graph, FCT, 2, 2)
    assert.are.equal(0, sub.depth[FCT])
  end)

  it("assigns negative depths upstream and positive downstream", function()
    local sub = lineage.select(graph, FCT, 2, 2)
    assert.are.equal(-1, sub.depth["model.jaffle_shop.stg_orders"])
    assert.are.equal(-2, sub.depth["source.jaffle_shop.jaffle.orders"])
    assert.are.equal(1, sub.depth["model.jaffle_shop.dim_customers"])
  end)

  it("respects the upstream depth cap", function()
    local sub = lineage.select(graph, FCT, 1, 2)
    assert.is_not_nil(sub.depth["model.jaffle_shop.stg_orders"])
    assert.is_nil(sub.depth["source.jaffle_shop.jaffle.orders"])
  end)

  it("respects the downstream depth cap", function()
    local sub = lineage.select(graph, FCT, 2, 0)
    assert.is_nil(sub.depth["model.jaffle_shop.dim_customers"])
  end)

  it("selects only the root at depth 0/0", function()
    local sub = lineage.select(graph, FCT, 0, 0)
    local count = 0
    for _ in pairs(sub.depth) do count = count + 1 end
    assert.are.equal(1, count)
  end)

  it("drops edges pointing at unselected nodes", function()
    -- stg_orders is selected at depth -1 but its own parent is not; the
    -- induced subgraph must not keep that dangling edge.
    local sub = lineage.select(graph, FCT, 1, 1)
    assert.are.same({}, sub.parents["model.jaffle_shop.stg_orders"])
  end)

  it("keeps the smaller absolute depth when a diamond reaches a node twice", function()
    local g = graph_from_edges({ { "a", "b" }, { "b", "c" }, { "a", "c" } })
    local sub = lineage.select(g, "c", 3, 0)
    assert.are.equal(-1, sub.depth["a"])
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/dbt-forge/lineage_spec.lua`
Expected: FAIL — `module 'dbt-forge.lineage' not found`.

- [ ] **Step 3: Write the implementation**

Create `lua/dbt-forge/lineage.lua`:

```lua
-- Pure graph layout. This module must never reference vim.* — it is unit
-- tested under bare luajit with no editor present.
local M = {}

-- Walks `graph` outward from `root_id` and returns the depth-bounded induced
-- subgraph: signed depths plus parent/child maps containing only edges whose
-- BOTH endpoints survived selection.
function M.select(graph, root_id, up_depth, down_depth)
  local depth = { [root_id] = 0 }

  local function bfs(map, limit, sign)
    local frontier = { root_id }
    for hop = 1, limit do
      local next_frontier = {}
      for _, id in ipairs(frontier) do
        for _, neighbour in ipairs(map[id] or {}) do
          local d = sign * hop
          if depth[neighbour] == nil or math.abs(d) < math.abs(depth[neighbour]) then
            depth[neighbour] = d
            table.insert(next_frontier, neighbour)
          end
        end
      end
      frontier = next_frontier
      if #frontier == 0 then
        break
      end
    end
  end

  bfs(graph.parents, up_depth, -1)
  bfs(graph.children, down_depth, 1)
  depth[root_id] = 0

  local parents, children = {}, {}
  for id in pairs(depth) do
    parents[id], children[id] = {}, {}
  end
  for id in pairs(depth) do
    for _, child in ipairs(graph.children[id] or {}) do
      if depth[child] ~= nil then
        table.insert(children[id], child)
        table.insert(parents[child], id)
      end
    end
  end
  for _, list in pairs(children) do
    table.sort(list)
  end
  for _, list in pairs(parents) do
    table.sort(list)
  end

  return { depth = depth, parents = parents, children = children }
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `busted tests/dbt-forge/lineage_spec.lua`
Expected: PASS — 7 successes.

- [ ] **Step 5: Commit**

```bash
git add lua/dbt-forge/lineage.lua tests/dbt-forge/lineage_spec.lua
git commit -m "feat: select depth-bounded induced lineage subgraph"
```

---

### Task 6: Phase 1 renderer — dual tree

**Files:**
- Create: `lua/dbt-forge/render.lua`
- Test: `tests/dbt-forge/render_spec.lua`

**Interfaces:**
- Consumes: `graph` (Task 3), `sub` (Task 5).
- Produces:
  - `render.tree_rows(graph, sub, root_id) -> rows` using the Shared Row Contract.
  - `render.format(graph, row, width) -> text, spans` where `spans` is a list of `{ hl_group, start_col, end_col }` (0-indexed byte columns, end exclusive).

**This module must not reference `vim.*`.**

- [ ] **Step 1: Write the failing test**

Create `tests/dbt-forge/render_spec.lua`:

```lua
local render = require("dbt-forge.render")
local lineage = require("dbt-forge.lineage")
local manifest = require("dbt-forge.manifest")
local fixture = require("fixtures.manifest_fixture")

local ALL = { "model", "source", "seed", "snapshot", "exposure" }
local FCT = "model.jaffle_shop.fct_orders"

local function texts(graph, rows, width)
  local out = {}
  for _, row in ipairs(rows) do
    local text = render.format(graph, row, width)
    table.insert(out, text)
  end
  return out
end

describe("render.tree_rows", function()
  local graph, sub, rows

  before_each(function()
    graph = manifest.project(fixture(), ALL)
    sub = lineage.select(graph, FCT, 2, 2)
    rows = render.tree_rows(graph, sub, FCT)
  end)

  it("marks exactly one row as the root", function()
    local roots = 0
    for _, row in ipairs(rows) do
      if row.is_root then roots = roots + 1 end
    end
    assert.are.equal(1, roots)
  end)

  it("emits upstream and downstream headers", function()
    local headers = {}
    for _, row in ipairs(rows) do
      if row.kind == "header" then table.insert(headers, row.text) end
    end
    assert.are.same({ "▲ UPSTREAM", "▼ DOWNSTREAM" }, headers)
  end)

  it("includes every selected node at least once", function()
    local seen = {}
    for _, row in ipairs(rows) do
      if row.kind == "node" then seen[row.id] = true end
    end
    for id in pairs(sub.depth) do
      assert.is_true(seen[id] == true, "missing " .. id)
    end
  end)

  it("uses └─ for the last child at a level and ├─ otherwise", function()
    local gutters = {}
    for _, row in ipairs(rows) do
      if row.kind == "node" and not row.is_root then
        table.insert(gutters, row.gutter)
      end
    end
    local has_tee, has_elbow = false, false
    for _, g in ipairs(gutters) do
      if g:find("├─", 1, true) then has_tee = true end
      if g:find("└─", 1, true) then has_elbow = true end
    end
    assert.is_true(has_tee)
    assert.is_true(has_elbow)
  end)

  it("produces deterministic output across runs", function()
    local again = render.tree_rows(graph, lineage.select(graph, FCT, 2, 2), FCT)
    assert.are.same(texts(graph, rows, 48), texts(graph, again, 48))
  end)
end)

describe("render.format", function()
  local graph

  before_each(function()
    graph = manifest.project(fixture(), ALL)
  end)

  it("renders a node as gutter, glyph, name and materialization", function()
    local text = render.format(graph, {
      kind = "node", id = FCT, gutter = "├─ ", is_root = false,
    }, 48)
    assert.is_truthy(text:find("●", 1, true))
    assert.is_truthy(text:find("fct_orders", 1, true))
    assert.is_truthy(text:find("table", 1, true))
  end)

  it("uses the root glyph for the root row", function()
    local text = render.format(graph, {
      kind = "node", id = FCT, gutter = "", is_root = true,
    }, 48)
    assert.is_truthy(text:find("◉", 1, true))
  end)

  it("highlights ephemeral models distinctly", function()
    local _, spans = render.format(graph, {
      kind = "node", id = "model.jaffle_shop.int_payments_pivoted",
      gutter = "", is_root = false,
    }, 48)
    local groups = {}
    for _, span in ipairs(spans) do groups[span[1]] = true end
    assert.is_true(groups["DbtForgeLineageEphemeral"] == true)
  end)

  it("highlights sources distinctly", function()
    local _, spans = render.format(graph, {
      kind = "node", id = "source.jaffle_shop.jaffle.orders", gutter = "", is_root = false,
    }, 48)
    local groups = {}
    for _, span in ipairs(spans) do groups[span[1]] = true end
    assert.is_true(groups["DbtForgeLineageSource"] == true)
  end)

  it("renders blank rows as empty strings", function()
    assert.are.equal("", render.format(graph, { kind = "blank" }, 48))
  end)

  it("truncates long names rather than wrapping", function()
    local g = { nodes = { ["x"] = {
      name = string.rep("a", 200), resource_type = "model",
      materialized = "table", path = "x.sql",
    } } }
    local text = render.format(g, { kind = "node", id = "x", gutter = "", is_root = false }, 48)
    assert.is_true(#text <= 48)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/dbt-forge/render_spec.lua`
Expected: FAIL — `module 'dbt-forge.render' not found`.

- [ ] **Step 3: Write the implementation**

Create `lua/dbt-forge/render.lua`:

```lua
-- Pure presentation. This module must never reference vim.* — it is unit
-- tested under bare luajit with no editor present.
local M = {}

local ROOT_GLYPH = "◉"
local NODE_GLYPH = "●"

local HL_BY_TYPE = {
  source = "DbtForgeLineageSource",
  seed = "DbtForgeLineageSource",
  snapshot = "DbtForgeLineageSource",
  exposure = "DbtForgeLineageSource",
}

-- Lua's `#` counts bytes, but gutters and glyphs are multi-byte UTF-8. These
-- helpers count and slice by character so column maths stays honest.
local function utf8_len(s)
  local _, count = s:gsub("[^\128-\191]", "")
  return count
end

local function utf8_sub(s, chars)
  local count, byte_index = 0, 0
  for i = 1, #s do
    if s:byte(i) < 128 or s:byte(i) >= 192 then
      count = count + 1
      if count > chars then
        return s:sub(1, byte_index)
      end
    end
    byte_index = i
  end
  return s
end

local function hl_for(node, is_root)
  if is_root then
    return "DbtForgeLineageRoot"
  end
  if node.materialized == "ephemeral" then
    return "DbtForgeLineageEphemeral"
  end
  return HL_BY_TYPE[node.resource_type] or "DbtForgeLineageNode"
end

-- Returns the line text plus highlight spans as { hl_group, start_col, end_col }
-- with 0-indexed byte columns and an exclusive end, matching nvim extmarks.
function M.format(graph, row, width)
  if row.kind == "blank" then
    return "", {}
  end
  if row.kind == "header" then
    return row.text, { { "DbtForgeLineageHeader", 0, #row.text } }
  end
  if row.kind == "connector" then
    return row.gutter, { { "DbtForgeLineageRail", 0, #row.gutter } }
  end

  local node = graph.nodes[row.id]
  local gutter = row.gutter or ""
  local glyph = row.is_root and ROOT_GLYPH or NODE_GLYPH

  local spans = {}
  local col = 0
  if #gutter > 0 then
    table.insert(spans, { "DbtForgeLineageRail", 0, #gutter })
    col = #gutter
  end

  table.insert(spans, { hl_for(node, row.is_root), col, col + #glyph })
  col = col + #glyph + 1

  -- Reserve room for " " .. materialization on the right, but never let the
  -- name shrink below something readable.
  local tag = node.materialized
  local used = utf8_len(gutter) + utf8_len(glyph) + 1
  local name_budget = math.max(8, width - used - utf8_len(tag) - 1)

  local name = node.name
  if utf8_len(name) > name_budget then
    name = utf8_sub(name, name_budget - 1) .. "…"
  end

  table.insert(spans, { hl_for(node, row.is_root), col, col + #name })

  local text = gutter .. glyph .. " " .. name
  local pad = width - utf8_len(text) - utf8_len(tag)
  if pad < 1 then
    pad = 1
  end
  local tag_col = #text + pad
  text = text .. string.rep(" ", pad) .. tag
  table.insert(spans, { "DbtForgeLineageMaterialization", tag_col, tag_col + #tag })

  return text, spans
end

-- Phase 1 renderer: ancestors as one indented tree, descendants as another.
-- Shared parents are repeated rather than merged; the rail renderer in
-- render.rail_rows draws them as a single node with real edges.
function M.tree_rows(graph, sub, root_id)
  local rows = {}

  local function walk(id, map_key, prefix)
    local kids = sub[map_key][id] or {}
    for i, kid in ipairs(kids) do
      local last = (i == #kids)
      table.insert(rows, {
        kind = "node",
        id = kid,
        gutter = prefix .. (last and "└─ " or "├─ "),
        is_root = false,
      })
      walk(kid, map_key, prefix .. (last and "   " or "│  "))
    end
  end

  local has_upstream = #(sub.parents[root_id] or {}) > 0
  local has_downstream = #(sub.children[root_id] or {}) > 0

  if has_upstream then
    table.insert(rows, { kind = "header", text = "▲ UPSTREAM" })
    walk(root_id, "parents", "")
    table.insert(rows, { kind = "blank" })
  end

  table.insert(rows, { kind = "node", id = root_id, gutter = "", is_root = true })

  if has_downstream then
    table.insert(rows, { kind = "blank" })
    table.insert(rows, { kind = "header", text = "▼ DOWNSTREAM" })
    walk(root_id, "children", "")
  end

  return rows
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `busted tests/dbt-forge/render_spec.lua`
Expected: PASS — 11 successes.

- [ ] **Step 5: Run the whole suite**

Run: `busted`
Expected: PASS — no regressions.

- [ ] **Step 6: Commit**

```bash
git add lua/dbt-forge/render.lua tests/dbt-forge/render_spec.lua
git commit -m "feat: add dual-tree lineage renderer"
```

---

### Task 7: Configuration

**Files:**
- Modify: `lua/dbt-forge/config.lua`
- Test: `tests/dbt-forge/config_spec.lua`

**Interfaces:**
- Produces: `config.options.keymaps.lineage`, `config.options.lineage.{up_depth,down_depth,width,follow,include}`.

- [ ] **Step 1: Write the failing test**

Append to `tests/dbt-forge/config_spec.lua`:

```lua
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/dbt-forge/config_spec.lua`
Expected: FAIL — `attempt to index field 'lineage' (a nil value)`.

- [ ] **Step 3: Add the defaults**

In `lua/dbt-forge/config.lua`, add `lineage = "<leader>dl",` to the `keymaps` table, and add this block after `keymaps`:

```lua
  lineage = {
    up_depth = 2,
    down_depth = 2,
    width = 48,
    follow = true,
    include = { "model", "source", "seed", "snapshot", "exposure" },
  },
```

- [ ] **Step 4: Run test to verify it passes**

Run: `busted tests/dbt-forge/config_spec.lua`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lua/dbt-forge/config.lua tests/dbt-forge/config_spec.lua
git commit -m "feat: add lineage configuration defaults"
```

---

### Task 8: The sidebar — window, buffer, keymaps

This is the task that turns the pure modules into a usable feature. At the end of it Phase 1 ships.

**Files:**
- Create: `lua/dbt-forge/lineage_view.lua`
- Modify: `lua/dbt-forge/init.lua`, `plugin/dbt-forge.lua`

**Interfaces:**
- Consumes: `manifest.load`, `manifest.resolve`, `manifest.invalidate` (Tasks 3-4); `lineage.select` (Task 5); `render.tree_rows`, `render.format` (Task 6); `config.options.lineage` (Task 7); `goto.resolve_source` — note this is currently a file-local function at `lua/dbt-forge/goto.lua:127` and must be exported as `M.resolve_source` in Step 3.
- Produces: `lineage_view.open()`, `lineage_view.close()`, `lineage_view.is_open()`, `lineage_view.refocus(node_id)`; `init.show_lineage()`.

- [ ] **Step 1: Define the highlight groups and window scaffolding**

Create `lua/dbt-forge/lineage_view.lua`:

```lua
local M = {}

local config = require("dbt-forge.config")
local manifest = require("dbt-forge.manifest")
local lineage = require("dbt-forge.lineage")
local render = require("dbt-forge.render")

local ns = vim.api.nvim_create_namespace("dbt-forge-lineage")

-- Linked to stock groups so every colorscheme gets sensible output for free.
local HIGHLIGHTS = {
  DbtForgeLineageRail = "Comment",
  DbtForgeLineageNode = "Normal",
  DbtForgeLineageRoot = "Title",
  DbtForgeLineageSource = "Constant",
  DbtForgeLineageEphemeral = "Special",
  DbtForgeLineageMaterialization = "Comment",
  DbtForgeLineageHeader = "Statement",
  DbtForgeLineageStale = "WarningMsg",
}

local function ensure_highlights()
  for group, link in pairs(HIGHLIGHTS) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
  vim.api.nvim_set_hl(0, "DbtForgeLineageEphemeral", {
    link = "Special", italic = true, default = true,
  })
end

-- Sidebar state. `win`/`buf` are nil when closed.
local state = {
  win = nil,
  buf = nil,
  root_id = nil,
  up = nil,
  down = nil,
  line_to_node = {},
}

function M.is_open()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

local function age_label(mtime)
  local seconds = os.time() - mtime
  if seconds < 90 then
    return string.format("%ds old", seconds)
  elseif seconds < 5400 then
    return string.format("%dm old", math.floor(seconds / 60))
  end
  return string.format("%dh old", math.floor(seconds / 3600))
end

return M
```

- [ ] **Step 2: Add rendering into the buffer**

Insert before `return M` in `lua/dbt-forge/lineage_view.lua`:

```lua
local function draw(graph, sub, rows)
  local width = config.options.lineage.width
  local lines, all_spans = {}, {}
  state.line_to_node = {}

  for i, row in ipairs(rows) do
    local text, spans = render.format(graph, row, width)
    lines[i] = text
    all_spans[i] = spans
    if row.kind == "node" then
      state.line_to_node[i] = row.id
    end
  end

  vim.api.nvim_buf_set_option(state.buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)

  for lnum, spans in pairs(all_spans) do
    for _, span in ipairs(spans) do
      local hl_group, start_col, end_col = span[1], span[2], span[3]
      pcall(vim.api.nvim_buf_set_extmark, state.buf, ns, lnum - 1, start_col, {
        end_col = end_col,
        hl_group = hl_group,
      })
    end
  end

  vim.api.nvim_buf_set_option(state.buf, "modifiable", false)

  local node_count = 0
  for _ in pairs(sub.depth) do
    node_count = node_count + 1
  end

  vim.wo[state.win].winbar = string.format(
    "%s · ↑%d ↓%d · %d nodes · manifest %s",
    graph.nodes[state.root_id].name,
    state.up,
    state.down,
    node_count,
    age_label(graph.mtime or os.time())
  )
end

-- Rebuilds the graph for the current root/depth and repaints. Safe to call
-- repeatedly: the manifest is cached on mtime, so this is a few milliseconds.
local function rerender()
  local graph, err = manifest.load(
    config.options.dbt_project_path,
    config.options.lineage.include
  )
  if not graph then
    vim.notify("dbt-forge: " .. err, vim.log.levels.ERROR)
    return
  end
  if not graph.nodes[state.root_id] then
    vim.notify(
      "dbt-forge: model not in manifest — press R to run dbt parse",
      vim.log.levels.WARN
    )
    return
  end
  local sub = lineage.select(graph, state.root_id, state.up, state.down)
  draw(graph, sub, render.tree_rows(graph, sub, state.root_id))
end
```

- [ ] **Step 3: Export `resolve_source` from `goto.lua`**

Sources should open at their table definition in the yml, not line 1. `resolve_source` at `lua/dbt-forge/goto.lua:127` already does this but is file-local. Change its declaration from:

```lua
local function resolve_source(namespace, table_name)
```

to:

```lua
function M.resolve_source(namespace, table_name)
```

Then update its call site inside `resolve_word`/`goto_definition` (the only in-file caller) from `resolve_source(` to `M.resolve_source(`.

Run: `nvim --headless -c 'lua require("dbt-forge.goto")' -c 'qa'`
Expected: no error output.

- [ ] **Step 4: Add node opening and keymaps**

Insert before `return M` in `lua/dbt-forge/lineage_view.lua`:

```lua
local function node_under_cursor()
  local lnum = vim.api.nvim_win_get_cursor(state.win)[1]
  return state.line_to_node[lnum]
end

local function open_node(keep_focus)
  local node_id = node_under_cursor()
  if not node_id then
    return
  end

  local graph = manifest.load(
    config.options.dbt_project_path,
    config.options.lineage.include
  )
  if not graph then
    return
  end
  local node = graph.nodes[node_id]

  -- Sources live inside a yml alongside other tables, so jump to the table
  -- definition rather than line 1.
  if node.resource_type == "source" then
    local namespace, table_name = node.name:match("^([^.]+)%.(.+)$")
    local ok, target = pcall(require("dbt-forge.goto").resolve_source, namespace, table_name)
    if ok and target then
      vim.cmd("wincmd p")
      vim.cmd("edit " .. vim.fn.fnameescape(target.path))
      if target.line then
        vim.api.nvim_win_set_cursor(0, { target.line, 0 })
      end
      if keep_focus then
        vim.api.nvim_set_current_win(state.win)
      end
      return
    end
  end

  local path = config.options.dbt_project_path .. "/" .. node.path
  vim.cmd("wincmd p")
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  if keep_focus then
    vim.api.nvim_set_current_win(state.win)
  end
end

local function set_depth(delta)
  state.up = math.max(0, state.up + delta)
  state.down = math.max(0, state.down + delta)
  rerender()
end

local function reroot()
  local node_id = node_under_cursor()
  if not node_id then
    return
  end
  state.root_id = node_id
  rerender()
end

local function refresh()
  local utils = require("dbt-forge.utils")
  local loading = require("dbt-forge.loading")
  loading.show_loading("dbt parse")
  vim.fn.jobstart(utils.build_dbt_command("dbt parse"), {
    on_exit = function(_, code)
      loading.hide_loading()
      if code ~= 0 then
        vim.notify("dbt-forge: dbt parse failed", vim.log.levels.ERROR)
        return
      end
      manifest.invalidate()
      if M.is_open() then
        rerender()
      end
    end,
  })
end

local function set_keymaps()
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, {
      buffer = state.buf, nowait = true, silent = true, desc = desc,
    })
  end
  map("<CR>", function() open_node(false) end, "Open model")
  map("o", function() open_node(true) end, "Open model, keep focus")
  map("r", reroot, "Re-root lineage here")
  map("+", function() set_depth(1) end, "Widen lineage depth")
  map("-", function() set_depth(-1) end, "Narrow lineage depth")
  map("R", refresh, "Run dbt parse and reload")
  map("q", M.close, "Close lineage")
  map("<ESC>", M.close, "Close lineage")
end
```

- [ ] **Step 5: Add open/close/refocus**

Insert before `return M` in `lua/dbt-forge/lineage_view.lua`:

```lua
function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win, state.buf = nil, nil
  state.line_to_node = {}
end

-- Re-roots an already-open sidebar without stealing focus. Used by follow.
function M.refocus(node_id)
  if not M.is_open() then
    return
  end
  state.root_id = node_id
  rerender()
end

function M.open(root_id)
  ensure_highlights()

  state.root_id = root_id
  state.up = state.up or config.options.lineage.up_depth
  state.down = state.down or config.options.lineage.down_depth

  if M.is_open() then
    rerender()
    return
  end

  local previous = vim.api.nvim_get_current_win()

  vim.cmd("topleft vsplit")
  state.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(state.win, config.options.lineage.width)

  state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(state.win, state.buf)

  vim.api.nvim_buf_set_option(state.buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(state.buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(state.buf, "swapfile", false)
  vim.api.nvim_buf_set_option(state.buf, "filetype", "dbtlineage")
  vim.api.nvim_win_set_option(state.win, "wrap", false)
  vim.api.nvim_win_set_option(state.win, "number", false)
  vim.api.nvim_win_set_option(state.win, "relativenumber", false)
  vim.api.nvim_win_set_option(state.win, "cursorline", true)
  vim.api.nvim_win_set_option(state.win, "winfixwidth", true)
  vim.api.nvim_win_set_option(state.win, "signcolumn", "no")

  set_keymaps()
  rerender()

  -- `wincmd p` in open_node relies on the editing window being the previous
  -- one, so hand focus back and forth explicitly here.
  vim.api.nvim_set_current_win(previous)
  vim.api.nvim_set_current_win(state.win)
end
```

- [ ] **Step 6: Wire up the entry point**

Add to `lua/dbt-forge/init.lua`, before `M.goto_definition`:

```lua
function M.show_lineage()
  local utils_mod = require("dbt-forge.utils")
  if not utils_mod.is_sql_file() then
    vim.notify("Not a SQL file", vim.log.levels.WARN)
    return
  end

  local manifest = require("dbt-forge.manifest")
  local graph, err = manifest.load(
    config.options.dbt_project_path,
    config.options.lineage.include
  )
  if not graph then
    vim.notify("dbt-forge: " .. err, vim.log.levels.ERROR)
    return
  end

  local name = vim.fn.expand("%:t:r")
  local rel_path = vim.fn.expand("%:p"):gsub(
    "^" .. vim.pesc(config.options.dbt_project_path) .. "/", ""
  )
  local node_id = manifest.resolve(graph, name, rel_path)
  if not node_id then
    vim.notify(
      string.format("dbt-forge: %s not in manifest — run dbt parse", name),
      vim.log.levels.WARN
    )
    return
  end

  require("dbt-forge.lineage_view").open(node_id)
end
```

And in `M.setup`, after the `test_model` keymap block:

```lua
  if config.options.keymaps.lineage then
    vim.keymap.set("n", config.options.keymaps.lineage, M.show_lineage, {
      desc = "Show dbt model lineage",
      noremap = true,
      silent = true,
    })
  end
```

- [ ] **Step 7: Register the command**

Add to `plugin/dbt-forge.lua`, following the existing command definitions:

```lua
vim.api.nvim_create_user_command("DbtLineage", function()
  require("dbt-forge").show_lineage()
end, { desc = "Show dbt model lineage" })
```

- [ ] **Step 8: Verify it loads and the suite still passes**

Run: `nvim --headless -c 'lua require("dbt-forge").setup({})' -c 'qa' 2>&1`
Expected: no Lua errors (a warning about a missing `dbt_project.yml` is fine).

Run: `busted`
Expected: PASS — no regressions.

- [ ] **Step 9: Commit**

```bash
git add lua/dbt-forge/lineage_view.lua lua/dbt-forge/init.lua lua/dbt-forge/goto.lua plugin/dbt-forge.lua
git commit -m "feat: add lineage sidebar with navigation keymaps"
```

---

### Task 9: Auto-follow

**Files:**
- Modify: `lua/dbt-forge/init.lua`

**Interfaces:**
- Consumes: `lineage_view.is_open`, `lineage_view.refocus` (Task 8); `manifest.resolve` (Task 4).

- [ ] **Step 1: Add the autocmd**

Add to `M.setup` in `lua/dbt-forge/init.lua`, after the lineage keymap block:

```lua
  if config.options.lineage.follow then
    vim.api.nvim_create_autocmd("BufEnter", {
      pattern = "*.sql",
      callback = function()
        local view = require("dbt-forge.lineage_view")
        if not view.is_open() then
          return
        end
        local manifest = require("dbt-forge.manifest")
        local graph = manifest.load(
          config.options.dbt_project_path,
          config.options.lineage.include
        )
        if not graph then
          return
        end
        local rel_path = vim.fn.expand("%:p"):gsub(
          "^" .. vim.pesc(config.options.dbt_project_path) .. "/", ""
        )
        local node_id = manifest.resolve(graph, vim.fn.expand("%:t:r"), rel_path)
        -- Silently ignore buffers that are not models; following should never
        -- interrupt, only track.
        if node_id then
          view.refocus(node_id)
        end
      end,
    })
  end
```

- [ ] **Step 2: Verify it loads**

Run: `nvim --headless -c 'lua require("dbt-forge").setup({})' -c 'qa' 2>&1`
Expected: no Lua errors.

- [ ] **Step 3: Commit**

```bash
git add lua/dbt-forge/init.lua
git commit -m "feat: follow the active model buffer in the lineage sidebar"
```

---

### Task 10: `lineage.topo_sort()`

Phase 2 begins here.

**Files:**
- Modify: `lua/dbt-forge/lineage.lua`
- Test: `tests/dbt-forge/lineage_spec.lua`

**Interfaces:**
- Consumes: `graph` (Task 3), `sub` (Task 5).
- Produces: `lineage.topo_sort(graph, sub) -> { unique_id, ... }` — every node exactly once, parents always before children, ties broken by `(depth, name, unique_id)`.

- [ ] **Step 1: Write the failing test**

Append to `tests/dbt-forge/lineage_spec.lua`:

```lua
describe("lineage.topo_sort", function()
  local function position_map(order)
    local pos = {}
    for i, id in ipairs(order) do pos[id] = i end
    return pos
  end

  it("places every parent before its child", function()
    local g = graph_from_edges({ { "a", "b" }, { "b", "d" }, { "a", "c" }, { "c", "d" } })
    local sub = lineage.select(g, "a", 0, 3)
    local pos = position_map(lineage.topo_sort(g, sub))
    assert.is_true(pos["a"] < pos["b"])
    assert.is_true(pos["a"] < pos["c"])
    assert.is_true(pos["b"] < pos["d"])
    assert.is_true(pos["c"] < pos["d"])
  end)

  it("emits every selected node exactly once", function()
    local g = graph_from_edges({ { "a", "b" }, { "b", "d" }, { "a", "c" }, { "c", "d" } })
    local sub = lineage.select(g, "a", 0, 3)
    local order = lineage.topo_sort(g, sub)
    assert.are.equal(4, #order)
    local seen = {}
    for _, id in ipairs(order) do
      assert.is_nil(seen[id], id .. " emitted twice")
      seen[id] = true
    end
  end)

  it("is deterministic across repeated runs", function()
    local g = graph_from_edges({ { "a", "b" }, { "a", "c" }, { "a", "d" }, { "b", "e" } })
    local sub = lineage.select(g, "a", 0, 3)
    local first = lineage.topo_sort(g, sub)
    for _ = 1, 5 do
      assert.are.same(first, lineage.topo_sort(g, lineage.select(g, "a", 0, 3)))
    end
  end)

  it("orders upstream nodes before the root", function()
    local graph = manifest.project(fixture(), ALL)
    local sub = lineage.select(graph, FCT, 2, 2)
    local pos = position_map(lineage.topo_sort(graph, sub))
    assert.is_true(pos["source.jaffle_shop.jaffle.orders"] < pos[FCT])
    assert.is_true(pos["model.jaffle_shop.stg_orders"] < pos[FCT])
    assert.is_true(pos[FCT] < pos["model.jaffle_shop.dim_customers"])
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/dbt-forge/lineage_spec.lua`
Expected: FAIL — `attempt to call field 'topo_sort' (a nil value)`.

- [ ] **Step 3: Write the implementation**

Add to `lua/dbt-forge/lineage.lua`, above `return M`:

```lua
-- Kahn's algorithm. The ordering is what makes rails possible at all: with
-- every parent emitted before its children, all edges point downward in the
-- buffer and no rail ever has to route backwards.
--
-- Ties break on (depth, name, unique_id) — a total order, so output is
-- byte-identical across runs and therefore assertable in tests.
function M.topo_sort(graph, sub)
  local function less(a, b)
    if sub.depth[a] ~= sub.depth[b] then
      return sub.depth[a] < sub.depth[b]
    end
    local name_a = graph.nodes[a] and graph.nodes[a].name or a
    local name_b = graph.nodes[b] and graph.nodes[b].name or b
    if name_a ~= name_b then
      return name_a < name_b
    end
    return a < b
  end

  local indegree, ready = {}, {}
  for id in pairs(sub.depth) do
    indegree[id] = #sub.parents[id]
    if indegree[id] == 0 then
      table.insert(ready, id)
    end
  end
  table.sort(ready, less)

  local order = {}
  while #ready > 0 do
    local node = table.remove(ready, 1)
    table.insert(order, node)
    local unlocked = false
    for _, child in ipairs(sub.children[node]) do
      indegree[child] = indegree[child] - 1
      if indegree[child] == 0 then
        table.insert(ready, child)
        unlocked = true
      end
    end
    -- Re-sorting is O(n log n) per unlock, so worst case O(n² log n). Graphs
    -- here are depth-capped to a few hundred nodes; this is not the bottleneck.
    if unlocked then
      table.sort(ready, less)
    end
  end

  return order
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `busted tests/dbt-forge/lineage_spec.lua`
Expected: PASS — 11 successes.

- [ ] **Step 5: Commit**

```bash
git add lua/dbt-forge/lineage.lua tests/dbt-forge/lineage_spec.lua
git commit -m "feat: topologically sort the lineage subgraph"
```

---

### Task 11: `lineage.assign_lanes()` — the rail algorithm

The crux of the feature. Read the two notes below before writing code.

**Note 1 — no `merges`.** The design spec's pseudocode collects converging lanes into a `merges` field. That branch is unreachable, so it is omitted here: we check for an already-open lane before allocating one, and topological order guarantees a node's lane stays open until the node is emitted. Two lanes therefore can never target the same node. Convergence appears as a `split` pointing at a lane that already existed in `lanes`.

**Note 2 — `false`, not `nil`.** A free lane is `false`. Using `nil` puts holes in the array, and `#t` on a table with holes is undefined in Lua — this algorithm indexes by `#lanes` constantly.

**Files:**
- Modify: `lua/dbt-forge/lineage.lua`
- Test: `tests/dbt-forge/lineage_spec.lua`

**Interfaces:**
- Consumes: `sub` (Task 5), `order` (Task 10).
- Produces: `lineage.assign_lanes(sub, order, root_id) -> rows` where each row is:
  ```lua
  {
    id = unique_id,
    lane = int,              -- 1-indexed column this node occupies
    lanes = { id|false },    -- lane occupancy BEFORE this node opened its children
    splits = { int },        -- lane indices this node connects across to
    depth = signed_int,
    is_root = boolean,
  }
  ```
- Produces: `lineage.build(graph, root_id, up, down) -> rows` composing select → topo_sort → assign_lanes.

- [ ] **Step 1: Write the failing test**

Append to `tests/dbt-forge/lineage_spec.lua`:

```lua
describe("lineage.assign_lanes", function()
  local function rows_for(edges, root, up, down)
    local g = graph_from_edges(edges)
    local sub = lineage.select(g, root, up, down)
    return lineage.assign_lanes(sub, lineage.topo_sort(g, sub), root), g
  end

  local function by_id(rows)
    local map = {}
    for _, row in ipairs(rows) do map[row.id] = row end
    return map
  end

  it("keeps a linear chain in a single lane", function()
    local rows = rows_for({ { "a", "b" }, { "b", "c" } }, "a", 0, 3)
    for _, row in ipairs(rows) do
      assert.are.equal(1, row.lane)
      assert.are.same({}, row.splits)
    end
  end)

  it("opens a second lane for a fan-out", function()
    local rows = by_id(rows_for({ { "a", "b" }, { "a", "c" } }, "a", 0, 2))
    assert.are.equal(1, rows["a"].lane)
    assert.are.same({ 2 }, rows["a"].splits)
    assert.are.equal(1, rows["b"].lane)
    assert.are.equal(2, rows["c"].lane)
  end)

  it("opens one lane per extra child on a wide fan-out", function()
    local rows = by_id(rows_for({ { "a", "b" }, { "a", "c" }, { "a", "d" } }, "a", 0, 2))
    assert.are.same({ 2, 3 }, rows["a"].splits)
  end)

  it("reuses an existing lane when a diamond reconverges", function()
    -- a→b, a→c, b→d, c→d. Order is a, b, c, d. b opens d's lane; when c is
    -- emitted it must connect across to that lane, not allocate a new one.
    local rows = by_id(rows_for({ { "a", "b" }, { "a", "c" }, { "b", "d" }, { "c", "d" } }, "a", 0, 3))
    assert.are.equal(1, rows["b"].lane)
    assert.are.equal(2, rows["c"].lane)
    assert.are.same({ 1 }, rows["c"].splits)
    assert.are.equal(1, rows["d"].lane)
  end)

  it("never gives two lanes the same target", function()
    local rows = rows_for({ { "a", "b" }, { "a", "c" }, { "b", "d" }, { "c", "d" } }, "a", 0, 3)
    for _, row in ipairs(rows) do
      local seen = {}
      for _, target in ipairs(row.lanes) do
        if target then
          assert.is_nil(seen[target], "two lanes target " .. tostring(target))
          seen[target] = true
        end
      end
    end
  end)

  it("uses false rather than nil for free lanes", function()
    local rows = rows_for({ { "a", "b" }, { "a", "c" }, { "b", "d" }, { "c", "d" } }, "a", 0, 3)
    for _, row in ipairs(rows) do
      for i = 1, #row.lanes do
        assert.is_not_nil(row.lanes[i], "lane " .. i .. " is a nil hole")
      end
    end
  end)

  it("holds a lane open across intervening rows", function()
    -- a→b, a→e, b→c, c→d. e's lane must stay occupied while b, c, d emit.
    local rows = by_id(rows_for(
      { { "a", "b" }, { "a", "e" }, { "b", "c" }, { "c", "d" } }, "a", 0, 4
    ))
    assert.are.equal(2, rows["e"].lane)
    assert.are.equal("e", rows["c"].lanes[2])
  end)

  it("marks exactly one row as root", function()
    local rows = rows_for({ { "a", "b" }, { "b", "c" } }, "b", 1, 1)
    local roots = 0
    for _, row in ipairs(rows) do
      if row.is_root then roots = roots + 1 end
    end
    assert.are.equal(1, roots)
  end)
end)

describe("lineage.build", function()
  it("composes selection, ordering and lane assignment", function()
    local graph = manifest.project(fixture(), ALL)
    local rows = lineage.build(graph, FCT, 2, 2)
    assert.is_true(#rows > 0)
    local ids = {}
    for _, row in ipairs(rows) do ids[row.id] = true end
    assert.is_true(ids[FCT])
    assert.is_true(ids["model.jaffle_shop.dim_customers"])
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/dbt-forge/lineage_spec.lua`
Expected: FAIL — `attempt to call field 'assign_lanes' (a nil value)`.

- [ ] **Step 3: Write the implementation**

Add to `lua/dbt-forge/lineage.lua`, above `return M`:

```lua
-- A free lane is `false`, never nil: `#t` on a table with nil holes is
-- undefined in Lua and this algorithm indexes by #lanes throughout.
local FREE = false

local function first_free(lanes)
  for i = 1, #lanes do
    if lanes[i] == FREE then
      return i
    end
  end
  return #lanes + 1
end

local function lane_targeting(lanes, id)
  for i = 1, #lanes do
    if lanes[i] == id then
      return i
    end
  end
  return nil
end

-- Assigns each node a rail lane, git-log style. Requires `order` to be
-- topologically sorted so that every edge points downward.
--
-- There is deliberately no `merges` output: because we reuse an already-open
-- lane rather than allocating a second one, and a node's lane stays open until
-- the node itself is emitted, two lanes can never target the same node.
-- Convergence shows up as a split into a pre-existing lane.
function M.assign_lanes(sub, order, root_id)
  local lanes, rows = {}, {}

  for _, node in ipairs(order) do
    -- Claim the lane opened for this node by whichever parent got there first.
    local lane = lane_targeting(lanes, node)
    if not lane then
      lane = first_free(lanes)
    end
    lanes[lane] = FREE

    -- Snapshot occupancy before opening child lanes; this is what the renderer
    -- draws as pass-through rails on this row.
    local occupancy = {}
    for i = 1, #lanes do
      occupancy[i] = lanes[i]
    end

    local splits = {}
    for _, child in ipairs(sub.children[node]) do
      local existing = lane_targeting(lanes, child)
      if existing then
        -- Diamond: the child already has a lane from another parent.
        if existing ~= lane then
          table.insert(splits, existing)
        end
      elseif lanes[lane] == FREE then
        lanes[lane] = child
      else
        local target = first_free(lanes)
        lanes[target] = child
        table.insert(splits, target)
      end
    end

    while #lanes > 0 and lanes[#lanes] == FREE do
      table.remove(lanes)
    end

    table.sort(splits)
    table.insert(rows, {
      id = node,
      lane = lane,
      lanes = occupancy,
      splits = splits,
      depth = sub.depth[node],
      is_root = (node == root_id),
    })
  end

  return rows
end

function M.build(graph, root_id, up_depth, down_depth)
  local sub = M.select(graph, root_id, up_depth, down_depth)
  return M.assign_lanes(sub, M.topo_sort(graph, sub), root_id), sub
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `busted tests/dbt-forge/lineage_spec.lua`
Expected: PASS — 20 successes.

- [ ] **Step 5: Commit**

```bash
git add lua/dbt-forge/lineage.lua tests/dbt-forge/lineage_spec.lua
git commit -m "feat: assign rail lanes to lineage nodes"
```

---

### Task 12: Phase 2 renderer — rails

**Files:**
- Modify: `lua/dbt-forge/render.lua`, `lua/dbt-forge/lineage_view.lua`
- Test: `tests/dbt-forge/render_spec.lua`

**Interfaces:**
- Consumes: `lineage.build` (Task 11).
- Produces: `render.rail_rows(graph, lane_rows, root_id) -> rows` using the Shared Row Contract.

- [ ] **Step 1: Write the failing test**

Append to `tests/dbt-forge/render_spec.lua`:

```lua
describe("render.rail_rows", function()
  local lineage_mod = require("dbt-forge.lineage")

  local function graph_from_edges(edges)
    local nodes, parents, children = {}, {}, {}
    local function ensure(id)
      if not nodes[id] then
        nodes[id] = { name = id, resource_type = "model", materialized = "view", path = id .. ".sql" }
        parents[id], children[id] = {}, {}
      end
    end
    for _, edge in ipairs(edges) do
      ensure(edge[1]); ensure(edge[2])
      table.insert(children[edge[1]], edge[2])
      table.insert(parents[edge[2]], edge[1])
    end
    for _, l in pairs(children) do table.sort(l) end
    for _, l in pairs(parents) do table.sort(l) end
    return { nodes = nodes, parents = parents, children = children, by_name = {} }
  end

  it("emits one node row per graph node", function()
    local g = graph_from_edges({ { "a", "b" }, { "b", "c" } })
    local lane_rows = lineage_mod.build(g, "a", 0, 3)
    local rows = render.rail_rows(g, lane_rows, "a")
    local node_rows = 0
    for _, row in ipairs(rows) do
      if row.kind == "node" then node_rows = node_rows + 1 end
    end
    assert.are.equal(3, node_rows)
  end)

  it("emits no connector rows for a linear chain", function()
    local g = graph_from_edges({ { "a", "b" }, { "b", "c" } })
    local rows = render.rail_rows(g, lineage_mod.build(g, "a", 0, 3), "a")
    for _, row in ipairs(rows) do
      assert.are_not.equal("connector", row.kind)
    end
  end)

  it("emits a connector row after a fan-out", function()
    local g = graph_from_edges({ { "a", "b" }, { "a", "c" } })
    local rows = render.rail_rows(g, lineage_mod.build(g, "a", 0, 2), "a")
    assert.are.equal("node", rows[1].kind)
    assert.are.equal("connector", rows[2].kind)
    assert.is_truthy(rows[2].gutter:find("┐", 1, true))
  end)

  it("draws pass-through rails for lanes held open", function()
    local g = graph_from_edges({ { "a", "b" }, { "a", "e" }, { "b", "c" } })
    local rows = render.rail_rows(g, lineage_mod.build(g, "a", 0, 3), "a")
    local c_row
    for _, row in ipairs(rows) do
      if row.kind == "node" and row.id == "c" then c_row = row end
    end
    assert.is_not_nil(c_row)
    -- c sits in lane 1 with e's lane still open to its right.
    assert.is_truthy(c_row.gutter:find("│", 1, true))
  end)

  it("keeps line_to_node aligned by leaving connectors without an id", function()
    local g = graph_from_edges({ { "a", "b" }, { "a", "c" } })
    local rows = render.rail_rows(g, lineage_mod.build(g, "a", 0, 2), "a")
    for _, row in ipairs(rows) do
      if row.kind == "connector" then
        assert.is_nil(row.id)
      end
    end
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/dbt-forge/render_spec.lua`
Expected: FAIL — `attempt to call field 'rail_rows' (a nil value)`.

- [ ] **Step 3: Write the implementation**

Add to `lua/dbt-forge/render.lua`, above `return M`:

```lua
-- Builds the rail gutter for a node row: the node's own lane gets a space
-- (the glyph is appended by M.format), every other occupied lane a pass-through.
local function node_gutter(row)
  local width = math.max(row.lane, #row.lanes)
  local cells = {}
  for i = 1, width do
    if i == row.lane then
      cells[i] = ""
    elseif row.lanes[i] then
      cells[i] = "│"
    else
      cells[i] = " "
    end
  end
  -- Two columns per lane keeps rails readable; the node's own cell collapses
  -- so M.format's glyph lands exactly on it.
  local out = {}
  for i = 1, width do
    if i == row.lane then
      break
    end
    table.insert(out, cells[i] == "" and " " or cells[i])
    table.insert(out, " ")
  end
  return table.concat(out)
end

-- Builds the connector row drawn beneath a node that opens or joins lanes.
local function connector_gutter(row)
  local targets = {}
  for _, lane in ipairs(row.splits) do
    targets[lane] = true
  end
  local rightmost = row.lane
  for lane in pairs(targets) do
    if lane > rightmost then
      rightmost = lane
    end
  end
  local leftmost = row.lane
  for lane in pairs(targets) do
    if lane < leftmost then
      leftmost = lane
    end
  end

  local cells = {}
  for i = leftmost, rightmost do
    if i == row.lane then
      cells[#cells + 1] = "├"
    elseif targets[i] then
      cells[#cells + 1] = (i > row.lane) and "┐" or "┘"
    elseif row.lanes[i] then
      cells[#cells + 1] = "┼"
    else
      cells[#cells + 1] = "─"
    end
    if i < rightmost then
      cells[#cells + 1] = "─"
    end
  end

  return string.rep(" ", (leftmost - 1) * 2) .. table.concat(cells)
end

-- Phase 2 renderer: one row per node with rails in a left gutter, plus a
-- connector row wherever a node opens or joins lanes. Connector rows carry no
-- `id`, so line_to_node simply skips them.
function M.rail_rows(graph, lane_rows, root_id)
  local rows = {}
  for _, row in ipairs(lane_rows) do
    table.insert(rows, {
      kind = "node",
      id = row.id,
      gutter = node_gutter(row),
      is_root = row.is_root,
    })
    if #row.splits > 0 then
      table.insert(rows, { kind = "connector", gutter = connector_gutter(row) })
    end
  end
  return rows
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `busted tests/dbt-forge/render_spec.lua`
Expected: PASS — 16 successes.

- [ ] **Step 5: Swap the renderer in the sidebar**

In `lua/dbt-forge/lineage_view.lua`, replace the last two lines of `rerender()`:

```lua
  local sub = lineage.select(graph, state.root_id, state.up, state.down)
  draw(graph, sub, render.tree_rows(graph, sub, state.root_id))
```

with:

```lua
  local lane_rows, sub = lineage.build(graph, state.root_id, state.up, state.down)
  draw(graph, sub, render.rail_rows(graph, lane_rows, state.root_id))
```

`render.tree_rows` stays in the module — it is a working alternative renderer and costs nothing to keep.

- [ ] **Step 6: Verify the whole suite and that the plugin loads**

Run: `busted`
Expected: PASS — all specs green.

Run: `nvim --headless -c 'lua require("dbt-forge").setup({})' -c 'qa' 2>&1`
Expected: no Lua errors.

- [ ] **Step 7: Commit**

```bash
git add lua/dbt-forge/render.lua lua/dbt-forge/lineage_view.lua tests/dbt-forge/render_spec.lua
git commit -m "feat: render lineage as a vertical rail graph"
```

---

### Task 13: Manual verification and documentation

Every prior task was verified against a hand-written fixture. This task is the only check that the code works against a manifest dbt actually produced — do not skip it.

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Verify against a real dbt project**

In a real dbt project with a populated `target/manifest.json`, open a model with both upstream and downstream dependencies and run `:DbtLineage`. Confirm each of:

- The sidebar opens on the left at the configured width.
- The current model is marked with `◉` and every other node with `●`.
- Rails connect the nodes, and fan-out produces a visible `┐` connector row.
- Ephemeral models appear, italicised, labelled `ephemeral`.
- No test or macro nodes appear anywhere.
- Sources appear as `source_name.table_name`.
- The winbar shows the model name, depths, node count and manifest age.
- `+` widens the graph and the node count in the winbar rises; `-` narrows it.
- `<CR>` on a node opens that model in the editing window, sidebar still open.
- `<CR>` on a source lands on the table's definition in the yml, not line 1.
- `r` re-roots the graph on the node under the cursor.
- Opening a different model updates the sidebar automatically (follow).
- `R` runs `dbt parse` with the loading screen, then repaints with a fresh age.
- `q` closes the sidebar.

Record any failure and fix it before proceeding.

- [ ] **Step 2: Time it on the largest project available**

Run `:DbtLineage`, close it, and run it again. The second open should be effectively instant — that is the mtime cache doing its job. If it is not, the cache key is wrong.

- [ ] **Step 3: Document the feature**

In `README.md`, add to the Features list:

```markdown
- **Model Lineage**: Press `<leader>dl` for a navigable rail graph of everything upstream and downstream of the current model
```

Add to the commands table:

```markdown
| `:DbtLineage` | Show lineage for the current model |
```

Add a new section after "Goto Definition":

````markdown
## Model Lineage

Press `<leader>dl` in a model to open a lineage sidebar — a vertical rail graph
of the model's ancestors and descendants, read straight from
`target/manifest.json`.

| Key | Action |
|-----|--------|
| `<CR>` | Open the model under the cursor |
| `o` | Open it, but keep focus in the sidebar |
| `r` | Re-root the graph on the node under the cursor |
| `+` / `-` | Widen or narrow the depth shown |
| `R` | Run `dbt parse` and reload the manifest |
| `q` / `<ESC>` | Close |

Models, sources, seeds, snapshots and exposures are shown; tests and macros are
not. Ephemeral models are included and marked, since they are real links in the
dependency chain.

The graph comes from `target/manifest.json`, so it reflects the last time dbt
parsed your project — the sidebar shows the manifest's age, and `R` refreshes
it.

```lua
require("dbt-forge").setup({
  keymaps = { lineage = "<leader>dl" },
  lineage = {
    up_depth = 2,      -- hops upstream to show
    down_depth = 2,    -- hops downstream to show
    width = 48,        -- sidebar width in columns
    follow = true,     -- re-root when you switch model buffers
    include = { "model", "source", "seed", "snapshot", "exposure" },
  },
})
```
````

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: document the model lineage view"
```

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| `manifest.lua` projection, mtime cache, size guard | 3, 4 |
| Filter dependency maps, not just node set | 3 (tested) |
| Discard raw decoded table | 4 |
| Name resolution with path disambiguation | 4 |
| `lineage.select` — BFS, signed depth, induced subgraph | 5 |
| `lineage.topo_sort` — Kahn, deterministic tie-break | 10 |
| `lineage.assign_lanes` — lanes, splits, pass-throughs | 11 |
| Sidebar window, scratch buffer, winbar, extmarks | 8 |
| Highlight groups linked to stock groups | 8 |
| `line_to_node` contract | 8, 12 |
| All seven keymaps | 8 |
| Source opening via `goto.resolve_source` | 8 |
| Auto-follow on `BufEnter` | 9 |
| Config block and `:DbtLineage` | 7, 8 |
| All five error cases | 4, 8 |
| Phase 1 tree renderer, Phase 2 rail renderer | 6, 12 |
| README | 13 |

No gaps.

**Placeholder scan:** none — every code step carries complete implementations, and every test step carries real assertions.

**Type consistency:** `graph` (`nodes`/`parents`/`children`/`by_name`/`mtime`) is produced in Task 3 and consumed unchanged in 4, 5, 6, 8, 10, 11, 12. `sub` (`depth`/`parents`/`children`) is produced in Task 5 and consumed in 6, 10, 11. The Shared Row Contract is produced by `render.tree_rows` (6) and `render.rail_rows` (12) and consumed by `draw` (8). `lineage.build` returns `rows, sub` — both return values are used at the call site in Task 12 Step 5. `render.format(graph, row, width) -> text, spans` is defined in Task 6 and called in Tasks 6 and 8 with the same signature.
