# spellsitter.nvim

Spell checker for Neovim powered by [tree-sitter](https://github.com/tree-sitter/tree-sitter).

## Status
**WIP**

This plugin relies on Neovim's tree-sitter API which is still under development.
Expect things to break sometimes but please don't hesitate to raise an issue.

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
  hl = 'SpellBad',
  captures = {'comment'},  -- set to {} to spellcheck everything
}
```

## TODO

- [ ] Provide implementations for existing spell movement mappings: `]s`, `[s`
