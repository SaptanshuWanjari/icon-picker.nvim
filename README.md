# icon-picker.nvim

Lightweight Telescope picker for React icons.

- Sources: `lucide-react`, `react-icons/*`, `@iconify-json/*`
- Inserts JSX icon at cursor
- Adds safe import at top (`"use client"` aware)
- Handles multiline imports safely
- Optional terminal preview with `chafa`

## Demo

### Open Picker

![Demo](./assets/Open-Picker.gif)

### Change Source

![Demo](./assets/Change-Source.gif)

## Requirements

- Neovim >= 0.9
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
- Node project with `node_modules`
- At least one icon source package:
  - `lucide-react`
  - `react-icons`
  - `@iconify/react` plus one or more local icon sets, e.g. `@iconify-json/mdi`

Preview:

- `node`
- `chafa` (optional but recommended)
- `react` + `react-dom` for `react-icons` render preview path

## Installation (lazy.nvim)

```lua
{
  "SaptanshuWanjari/icon-picker.nvim",
  dependencies = {
    "nvim-telescope/telescope.nvim",
    "nvim-lua/plenary.nvim",
  },
  opts = {
    command = "IconPicker",
    keymaps = {
      normal = "<leader>ii",
      insert = "<C-g>i",
    },
    picker = {
      toggle_source_key = "<C-t>",
      notify_source_toggle = false,
      stopinsert_on_open = true,
      telescope = {},
    },
  },
  config = function(_, opts)
    require("icon_picker").setup(opts)
  end,
}
```

## Usage

- `:IconPicker`
- Choose a source first: `All sources`, `Lucide`, `React Icons`, or `Iconify`
- Select icon -> plugin inserts import + `<IconName />`
- Iconify selections insert `<Icon icon="prefix:name" />` from `@iconify/react`
- In the icon picker, `<C-t>` reopens the source selector and reloads the picker with the selected source only

## Configuration

```lua
require("icon_picker").setup({
  command = "IconPicker", -- set false/nil/"" to disable command
  keymaps = {
    normal = nil,          -- e.g. "<leader>ii"
    insert = nil,          -- e.g. "<C-g>i"
  },
  picker = {
    stopinsert_on_open = true,
    toggle_source_key = "<C-t>",
    notify_source_toggle = false,
    telescope = {
      -- any Telescope picker opts override
      -- layout_strategy = "horizontal",
      -- layout_config = { width = 0.95, height = 0.85 },
    },
  },
})
```

## Notes

- Import logic avoids destructive rewrite of complex imports.
- If source missing, picker filters automatically.
- Lucide preview has fallback path even when React render path fails.
- Iconify support is offline-only and reads installed `@iconify-json/{prefix}/icons.json` files.
- Selecting an unavailable source shows a warning instead of opening an empty picker.

## License

MIT
