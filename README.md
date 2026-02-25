# dbt-forge.nvim

A Neovim plugin for DBT development. Run, test, and transpile models, and navigate between refs, sources, and macros with goto definition — all without leaving your editor. Automatically detects your dbt project and Python environment.

## Features

- **Run DBT Models**: Execute `dbt run` on the current model file
- **Show Model Results**: Preview sample data from executed models
- **Transpile Models**: View compiled SQL for both incremental and full-refresh modes
- **Test Models**: Run `dbt test` on the current model
- **Goto Definition**: Press `gd` on Jinja references to jump to model files, source definitions, and macro definitions
- **Auto-detection**: Automatically finds your `dbt_project.yml` and Python environment (pyenv, conda, or venv)
- **Fast Workflow**: Execute commands without leaving your editor

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
    "gbakes/dbt-forge.nvim",
    url = "https://github.com/gbakes/dbt-forge.git",
    config = function()
        require("dbt-forge").setup({
        -- Configuration options here
        })
    end,
    ft = "sql", -- Load only for SQL files
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "gbakes/dbt-forge.nvim",
  config = function()
    require("dbt-forge").setup({
      -- Configuration options here
    })
  end
}
```

## Configuration

```lua
require("dbt-forge").setup({
  -- Not required but can be used to override
  -- dbt_project_path = "/path/to/your/dbt/project",
  -- python_env_manager = "pyenv",
  -- python_env_name = "your-env-name",
  keymaps = {
    run_model = "<leader>dr",
    transpile_model = "<leader>dt",
    test_model = "<leader>dT",
    goto_definition = "gd",
  },
  ui = {
    split_size = 15,
    float_border = "rounded",
  }
})
```

## Default Keymaps

| Keymap | Action |
|--------|--------|
| `<leader>dr` | Run the current DBT model |
| `<leader>dt` | Transpile and show compiled SQL in floating window |
| `<leader>dT` | Run tests for the current model |
| `gd` | Go to definition of ref, source, or macro under cursor |

## Commands

| Command | Action |
|---------|--------|
| `:DbtRun` | Run the current DBT model |
| `:DbtTranspile` | Transpile and show compiled SQL |
| `:DbtTest` | Run tests for the current model |
| `:DbtGotoDef` | Go to definition under cursor |

## Goto Definition

Press `gd` with your cursor on a Jinja reference in a dbt SQL file to jump to its definition:

| Reference | Example | Jumps To |
|-----------|---------|----------|
| Model ref | `{{ ref('my_model') }}` | `models/**/my_model.sql` |
| Source | `{{ source("raw_data", "my_table") }}` | `sources.yml` at the table definition |
| Macro | `{{ my_macro("col") }}` | `{% macro my_macro(` in `macros/` |
| Package macro | `{{ dbt_utils.generate_surrogate_key(...) }}` | Macro definition in `dbt_packages/` |

When the cursor is not on a Jinja reference, `gd` falls back to the default Vim behavior.

## Auto-detection

The plugin automatically detects:

- **DBT project path** — walks up from the current file looking for `dbt_project.yml`
- **Python environment** — checks for pyenv (`.python-version`), conda (`environment.yml`), or venv (`.venv`/`venv` directory). For pyenv, it resolves virtualenvs that have `dbt` installed.

Override auto-detection by setting `dbt_project_path`, `python_env_manager`, and `python_env_name` in `setup()`.

## Usage

1. Open any `.sql` file in your DBT models directory
2. Use the keymaps to run, test, or transpile your models
3. View results in terminal splits or floating windows
4. Use `gd` to navigate between models, sources, and macros

## Requirements

- Neovim >= 0.8.0
- DBT CLI installed and configured
- Python environment with DBT dependencies

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT
