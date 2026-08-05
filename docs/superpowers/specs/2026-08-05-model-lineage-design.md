# Model Lineage View — Design

**Date:** 2026-08-05
**Status:** Approved, ready for implementation planning

## Goal

Press `<leader>dl` in a dbt model buffer and get a navigable graph of everything
upstream and downstream of that model, rendered as a vertical rail graph in a
persistent sidebar — `git log --graph` for your DAG.

## Scope

**Included as graph nodes:** models (including ephemeral), sources, seeds,
snapshots, exposures.

**Excluded:** tests, unit tests, macros, metrics, semantic models, saved
queries. Disabled nodes are excluded for free — dbt puts them in the manifest's
`disabled` key rather than `nodes`, and omits them from the dependency maps.

Ephemeral models are deliberately retained: they are real links in the
dependency chain, and hiding them makes lineage look like it skips a hop.

## Key decisions

| Decision | Choice | Why |
|---|---|---|
| Renderer | Vertical rail graph, one node per row, rails in a left gutter | Both depth *and* fan-out consume rows, so the view never exceeds the split width — only the gutter grows, and it degrades gracefully |
| Orientation | Vertical | Neovim scrolls vertically for free and horizontally miserably; horizontal layered layout costs ~25 columns per layer and dies at four hops in an 80-column split |
| Data source | `target/manifest.json`, cached on mtime | Contains `parent_map`/`child_map` already — the exact adjacency lists, no dbt invocation. Sub-second open matters for something you glance at repeatedly |
| Staleness | Explicit: age shown in winbar, `R` to `dbt parse` and reload | Honest and simple; beats guessing, and avoids a 20s parse firing exactly when you have just edited a file |
| Size control | Depth cap (default 2 each way), `+`/`-` to widen live | Bounds node count and rail width together; mirrors the `2+model+2` selector idiom |
| Window | Persistent vertical split sidebar | Re-rooting and walk-the-DAG navigation only pay off in a view that survives being used |

### Rejected alternatives

- **`dbt ls --select +model+ --output json` per invocation.** Correct and never
  stale, and the selector syntax does traversal and resource filtering for you —
  meaningfully less code. Rejected on latency: a full project parse every time,
  3s small and 20-30s+ large. A lineage key you hesitate to press is a lineage
  key you stop pressing.
- **Layered boxes with siblings side-by-side.** Reads best as a diagram, but
  fan-out consumes width, so ten children needs ~250 columns plus sibling
  wrapping and `[+8 more]` collapsing to stay usable.
- **Unbounded graph with fold-based collapsing.** Folds fight rails: a rail's
  meaning depends on the rows above and below it being present, so collapsing a
  mid-graph subtree forces a full re-layout on every `za`.
- **Unbounded with a rail lane cap.** A 214-row buffer where a chunk of edges
  are an unresolved `↕n` marker is closer to a list than a graph.

## Architecture

Three new modules, split so the hard part needs no running editor:

| Module | Responsibility | Needs nvim? |
|---|---|---|
| `lua/dbt-forge/manifest.lua` | Locate, decode, cache and project `manifest.json` into a compact graph | `vim.json`, `fs_stat` only |
| `lua/dbt-forge/lineage.lua` | Traversal, topological sort, lane assignment. Pure: graph in → rows out | **No** |
| `lua/dbt-forge/lineage_view.lua` | Buffer, split window, extmark highlights, keymaps | Yes |

The purity of `lineage.lua` is load-bearing. The lane algorithm is the only
genuinely tricky code in this feature, and the existing busted setup runs specs
under bare `luajit` with no nvim — so a dependency-free layout module is
directly testable, while anything touching `vim.*` is not.

### `manifest.lua`

`M.load(project_path)` → `graph, err`. Reads `<project>/target/manifest.json`,
caches on mtime via `(vim.uv or vim.loop).fs_stat` (the `vim.uv` alias only
exists from 0.10, and this plugin supports 0.8).

```lua
graph = {
  nodes = {   -- keyed by unique_id
    ["model.jaffle.fct_orders"] = {
      name = "fct_orders",
      resource_type = "model",
      materialized = "table",                 -- config.materialized, or the
                                              -- resource type for non-models
      path = "models/marts/fct_orders.sql",   -- original_file_path
      package = "jaffle_shop",
    },
  },
  parents  = {},  -- unique_id → { unique_id }, from parent_map
  children = {},  -- unique_id → { unique_id }, from child_map
  by_name  = {},  -- name → { unique_id }, for filename → node lookup
  mtime    = 1234567890,
}
```

Projection rules:

- Retain nodes whose `resource_type` appears in `config.lineage.include`, drawn
  from the manifest's `nodes` key (models, seeds, snapshots) plus its separate
  `sources` and `exposures` keys. The config list is the single source of truth
  for this filter — nothing is hardcoded in the projection.
- `materialized` comes from `config.materialized` for models. Sources, seeds,
  snapshots and exposures have no such field — label them by resource type
  (`"source"`, `"seed"`, `"snapshot"`, `"exposure"`).
- Display name for sources is `source_name.name`; for everything else, `name`.
- **Filter the dependency maps, not just the node set.** `parent_map` and
  `child_map` contain test node ids. Dropping tests from `nodes` while copying
  the maps verbatim gives every model a dozen phantom test children.
- **Discard the raw decoded table immediately** after projecting. The decode is
  peak memory; retaining it is what would make this feel heavy on a large
  project.
- `fs_stat` size guard: warn before decoding if the file exceeds ~100MB.

Age for the winbar comes from file mtime, not `metadata.generated_at` — same
meaning, no ISO8601 parsing.

Name resolution takes `%:t:r` → `by_name`. When two packages define the same
model name, disambiguate by matching `original_file_path` against the buffer's
project-relative path.

### `lineage.lua`

`M.build(graph, root_id, up_depth, down_depth)` → `rows`.

1. **Select.** BFS up over `parents` and down over `children`, each to its depth
   cap. Signed `depth` per node (negative upstream, positive downstream). When a
   diamond makes a node reachable both ways, keep the smaller `|depth|`.
2. **Induce.** Keep only edges whose *both* endpoints survived selection.
   Skipping this draws rails to nodes that are not on screen.
3. **Topologically sort** the induced subgraph (Kahn), tie-broken by
   `(depth, name)` so output is deterministic and therefore assertable. This
   step is what makes rails possible at all: topo order guarantees every edge
   points *downward* in the buffer, so no rail ever routes backwards.
4. **Assign lanes** — the git-graph algorithm:

```
lanes = []      -- lanes[i] = pending target unique_id, or nil if free
rows  = []

for n in topo_order:
    -- claim a lane: leftmost lane already targeting n
    my, merges = nil, []
    for i, target in lanes:
        if target == n:
            if my == nil then my = i
            else merges.push(i); lanes[i] = nil    -- converging edge
    if my == nil then my = first_free_index(lanes)
    lanes[my] = nil                                -- consumed

    pre_lanes = snapshot(lanes)                    -- for pass-through rendering

    -- open lanes for children
    splits = []
    for k in children_in[n]:
        existing = index_of_lane_targeting(lanes, k)
        if existing then
            -- k already has a lane from another parent (diamond):
            -- connect across, do not allocate
            if existing ~= my then splits.push(existing)
        elseif lanes[my] == nil then
            lanes[my] = k                          -- first child continues my lane
        else
            j = first_free_index(lanes); lanes[j] = k; splits.push(j)

    rows.push{ id = n, lane = my, lanes = pre_lanes, merges = merges,
               splits = splits, depth = depth[n], is_root = (n == root_id) }

trim trailing free lanes
```

Lanes held open across intermediate rows render as `│` pass-throughs. Output is
data only — no strings, no buffer calls.

### `lineage_view.lua`

- `topleft vsplit`, `winfixwidth`, width from config (default 48). Scratch
  buffer, `nomodifiable`, `nowrap`, `cursorline`, `filetype=dbtlineage`.
- A pure `format_row()` builds the line text (also testable); colour is applied
  separately with `nvim_buf_set_extmark`, not syntax matching — per-cell
  precision is needed to colour rails differently from names on the same line.
- Status goes in the **winbar**, not a buffer line:
  `fct_orders · ↑2 ↓2 · 8 nodes · manifest 14m old`.
- Highlight groups link to stock groups so colorschemes work untouched:

| Group | Links to |
|---|---|
| `DbtForgeLineageRail` | `Comment` |
| `DbtForgeLineageRoot` | `Title` |
| `DbtForgeLineageSource` | `Constant` |
| `DbtForgeLineageEphemeral` | `Special` + italic |
| `DbtForgeLineageMaterialization` | `Comment` |
| `DbtForgeLineageStale` | `WarningMsg` |

- Node glyphs: `◉` root, `●` other nodes.

#### Line-to-node mapping

Merge and split connectors get their own lines (`├─┘`, `├─┐`), so buffer lines
are **not** strictly one-per-node. The renderer emits up to three lines per
node: an optional merge line, the node line, an optional split line.

The contract between renderer and keymaps is therefore a `line_to_node` table
mapping buffer line number → node id, `nil` on connector lines. Keymaps no-op
on `nil` lines. Phase 1's dual tree happens to be strictly 1:1; phase 2 is not,
and `line_to_node` absorbs the difference.

#### Keymaps (buffer-local)

| Key | Action |
|---|---|
| `<CR>` | Open node's file in the previous window |
| `o` | Open, keep focus in the sidebar |
| `r` | Re-root the graph on the node under the cursor, preserving current depth |
| `+` / `-` | Adjust depth and re-render. Both directions move together by one hop; floor of 0 (root alone), no ceiling |
| `R` | Run `dbt parse`, reload manifest, re-render |
| `q` / `<ESC>` | Close |

`+` and `-` are normal-mode motions; buffer-local overrides are fine.

#### Opening files

Resolve directly from `project_path .. "/" .. node.path` — no filesystem search
needed, since `original_file_path` is already in the manifest. **Except
sources**, which should land on the table definition inside the yml rather than
line 1; `goto.lua:127`'s `resolve_source` already does exactly that, so reuse
it.

#### Auto-follow

A `BufEnter` autocmd on `*.sql` re-roots the graph when the sidebar is open and
the new buffer is a node in the manifest. Config-gated. Cheap — re-BFS against
the cached graph is a few milliseconds.

## Configuration

```lua
keymaps = {
  lineage = "<leader>dl",
},
lineage = {
  up_depth   = 2,
  down_depth = 2,
  width      = 48,
  follow     = true,
  include    = { "model", "source", "seed", "snapshot", "exposure" },
},
```

Plus a `:DbtLineage` command, matching the existing `:DbtRun` / `:DbtTranspile`
/ `:DbtTest` set.

## Error handling

| Case | Behaviour |
|---|---|
| No `target/manifest.json` | Notify: run `dbt parse`, or press `R` |
| Decode fails (file caught mid-write) | Notify; retain last good cached graph |
| Current model absent from manifest | Notify: "`fct_new` not in manifest — press `R`" |
| Manifest exceeds ~100MB | Warn before decoding |
| Buffer is not a `.sql` file | Warn, matching existing `is_sql_file` guards |

## Testing

Specs go in `tests/dbt-forge/`, following the existing `config_spec.lua` /
`utils_spec.lua` pattern.

`lineage_spec.lua` — pure, no nvim stub required:

- depth bounds respected in both directions
- induced subgraph drops edges to unselected nodes
- topological order is deterministic across runs
- lane assignment: linear chain, diamond, wide fan-out, pass-through lanes,
  diamond re-convergence into an existing lane
- root pinning and `is_root` flag

`manifest_spec.lua` — projection from a small hand-written fixture manifest in
`tests/fixtures/`:

- tests and macros excluded from both nodes and dependency maps
- ephemeral models retained with `materialized == "ephemeral"`
- sources labelled and named as `source_name.name`
- mtime caching returns the identical table on an unchanged file

Render-layer coverage asserts `format_row()` output strings for a known graph,
keeping buffer and window calls out of the tested path.

**Note:** `busted` is not currently installed in this environment, so the
existing specs cannot be run as-is. Installing it (`luarocks install busted`)
is a prerequisite for verifying any of the above.

## Phasing

**Phase 1** — `manifest.lua` plus `lineage_view.lua` with a dual-tree renderer
(recursive indent, ancestors up and descendants down, shared parents repeated).
All keymaps, config, error handling and auto-follow working. Ships as a complete
feature.

**Phase 2** — add `lineage.lua`'s topological sort and lane assignment, and swap
the renderer. Because both phases produce rows plus a `line_to_node` map, phase
2 touches only the row builder and `format_row`: window management, keymaps,
highlights, `<CR>`, re-root, depth adjustment and follow all carry over
unchanged.
