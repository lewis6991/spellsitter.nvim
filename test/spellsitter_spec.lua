local helpers = require('test.functional.helpers')(after_each)
local Screen = require('test.functional.ui.screen')

local inspect = require('vim.inspect')

local feed          = helpers.feed
local clear         = helpers.clear
local command       = helpers.command
local exec_capture  = helpers.exec_capture
local exec_lua      = helpers.exec_lua

local pj_root = os.getenv('PJ_ROOT')

local function command_fmt(str, ...)
  command(str:format(...))
end

local function load_ts(file, lang)
  command_fmt("edit %s", file)
  exec_lua([[
    local parser = vim.treesitter.get_parser(0, ...)
    vim.treesitter.highlighter.new(parser)
  ]], lang)
end

describe('spellsitter', function()
  local screen

  before_each(function()
    clear()
    screen = Screen.new(30, 6)
    screen:attach()
    command('cd '..pj_root)

    screen:set_default_attr_ids({
      [1] = {foreground = Screen.colors.Blue1};
      [3] = {foreground = Screen.colors.Brown, bold = true};
      [4] = {foreground = Screen.colors.Cyan4};
      [5] = {foreground = Screen.colors.SlateBlue};
      [6] = {foreground = Screen.colors.SeaGreen4, bold = true};
      [7] = {background = Screen.colors.Red1, foreground = Screen.colors.Gray100};
    })

    exec_lua('package.path = ...', package.path)
  end)

  after_each(function()
    screen:detach()
  end)

  it('basic spellcheck', function()
    exec_lua('require("spellsitter").setup()')

    load_ts('test/dummy.c', 'c')

    screen:expect{grid=[[
      {1:^// spelling }{7:mstake}            |
      {1:// }{7:splling}{1: mistake}            |
      {1:// spelling }{7:mstake}            |
      {1:// }{7:splling}{1: mistake}            |
      {6:int} {4:main}{5:()} {5:{}                  |
                                    |
    ]]}

    feed('yyp')

    screen:expect{grid=[[
      {1:// spelling }{7:mstake}            |
      {1:^// spelling }{7:mstake}            |
      {1:// }{7:splling}{1: mistake}            |
      {1:// spelling }{7:mstake}            |
      {1:// }{7:splling}{1: mistake}            |
                                    |
    ]]}

  end)

end)
