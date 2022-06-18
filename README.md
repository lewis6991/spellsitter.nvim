# spellsitter.nvim

[![CI](https://github.com/lewis6991/spellsitter.nvim/workflows/CI/badge.svg?branch=master)](https://github.com/lewis6991/spellsitter.nvim/actions?query=workflow%3ACI)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Enable Neovim's builtin spellchecker for buffers with tree-sitter highlighting.

## What this plugin does

With `set spell`:

| Settings   | Result   |
| ------------- | ------------- |
| `syntax off`, Treesitter disabled  |  ![syntax off no treesitter](https://user-images.githubusercontent.com/7904185/160659719-bace62c4-eb62-4b10-a71b-2dcbf316518f.png) |
| `syntax on`, Treesitter disabled  | ![syntax_on_no_treesitter](https://user-images.githubusercontent.com/7904185/160659792-642f56be-48b9-47e5-8481-9f716e8d51ed.png) |
| Treesitter enabled | ![ts_no_spellsitter](https://user-images.githubusercontent.com/7904185/160659878-2af00775-ecdd-4a6c-b2f7-dcdc0f164e93.png) |
| Treesitter (with spellsitter), | ![ts_plus_spellsitter](https://user-images.githubusercontent.com/7904185/160660021-38927f03-5669-4425-a17a-053a2614d355.png) |


## Requirements
Neovim >= 0.5.0

## Installation

[packer.nvim](https://github.com/wbthomason/packer.nvim):
```lua
use {
  -- Optional but recommended
  -- 'nvim-treesitter/nvim-treesitter',
  'lewis6991/spellsitter.nvim',
}
```

[vim-plug](https://github.com/junegunn/vim-plug):
```vim
" Optional but recommended
" Plug 'nvim-treesitter/nvim-treesitter'
Plug 'lewis6991/spellsitter.nvim'
```

Note: This plugin does not depend on
[nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter)
however it is recommended in order to easily install tree-sitter parsers.

## Usage

For basic setup with all batteries included:
```lua
require('spellsitter').setup()
```

If using [packer.nvim](https://github.com/wbthomason/packer.nvim) spellsitter can
be setup directly in the plugin spec:

```lua
use {
  'lewis6991/spellsitter.nvim',
  config = function()
    require('spellsitter').setup()
  end
}
```

Configuration can be passed to the setup function. Here is an example with all
the default settings:

```lua
require('spellsitter').setup {
  -- Whether enabled, can be a list of filetypes, e.g. {'python', 'lua'}
  enable = true,
  debug = false
}
```

## Non-Goals

* Support external spellchecker backends.
