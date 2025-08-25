# dbt-forge.nvim

A Neovim plugin for DBT (Data Build Tool) development that allows you to run, test, and transpile DBT models directly from your editor.

## Features

- **Run DBT Models**: Execute `dbt run` on the current model file
- **Show Model Results**: Preview sample data from executed models
- **Transpile Models**: View compiled SQL for both incremental and full-refresh modes
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
  },
  ui = {
    split_size = 15,
    float_border = "rounded",
  }
})
```

## Default Keymaps

- `<leader>dr` - Run the current DBT model
- `<leader>dt` - Transpile and show compiled SQL in floating window
- `<leader>dT` - Run tests for the current model

## Usage

1. Open any `.sql` file in your DBT models directory
2. Use the keymaps to run, test, or transpile your models
3. View results in terminal splits or floating windows

## Requirements

- Neovim >= 0.8.0
- DBT CLI installed and configured
- Python environment with DBT dependencies

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT
