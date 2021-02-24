# spellsitter.nvim

Spell checker for Neovim powered by tree-sitter.

## Status
**WIP**

This plugin relies on Neovim's treesitter API which is still under development.
Expect things to break sometimes but please don't hesitate to raise an issue.

## Requirements
Neovim >= 0.5.0

## Installation

[packer.nvim](https://github.com/wbthomason/packer.nvim):
```lua
use {
  'lewis6991/spellsitter.nvim',
}
```

[vim-plug](https://github.com/junegunn/vim-plug):
```vim
Plug 'lewis6991/spellsitter.nvim'
```

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

## TODO

- [ ] Add word suggestions via pmenu.
- [ ] Provide implementations for existing spell related mappings: `]s`, `[s`, `zg`, etc.
