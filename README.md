# spellsitter.nvim

Spell checker for Neovim powered by [tree-sitter](https://github.com/tree-sitter/tree-sitter)
and [hunspell](http://hunspell.github.io/).

## Status
**WIP**

This plugin relies on Neovim's tree-sitter API which is still under development.
Expect things to break sometimes but please don't hesitate to raise an issue.

## Requirements
Neovim >= 0.5.0

## Installation

Firstly, make sure hunspell is installed (via `brew`, etc) and has dictionaries available to it.
You should see this kind of output:

```zsh
> echo helo | hunspell
Hunspell 1.7.0
& helo 11 0: hole, help, helot, hello, halo, hero, hell, held, helm, he lo, he-lo
```

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
  hunspell_cmd = 'hunspell',
  hunspell_args = {},
}
```

## TODO

- [ ] Add word suggestions via pmenu.
- [ ] Provide implementations for existing spell related mappings: `]s`, `[s`, `zg`, etc.
