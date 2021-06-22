local query = require'vim.treesitter.query'
local get_parser = vim.treesitter.get_parser

local api = vim.api

local M = {}

local cfg
local ns

local ffi = require("ffi")

local spell_check

local function setup_spellcheck()
  ffi.cdef[[
    typedef void win_T;

    typedef int ErrorType;

    typedef struct {
      ErrorType type;
      char *msg;
    } Error;

    win_T* find_window_by_handle(int window, Error *err);

    typedef int hlf_T;

    size_t spell_check(
      win_T *wp, const char *ptr, hlf_T *attrp,
      int *capcol, bool docount);
  ]]

  local capcol = ffi.new("int[1]", -1)
  local hlf = ffi.new("hlf_T[1]", 0)

  spell_check = function(win_handle, text)
    hlf[0] = 0
    capcol[0] = -1

    local len
    -- FIXME: Spell check can segfault on strings that begin with punctuation.
    -- Probably a bug in the C function.
    local leading_punc = text:match('^%p+')
    if leading_punc then
      len = #leading_punc
    else
      len = tonumber(ffi.C.spell_check(win_handle, text, hlf, capcol, false))
    end

    return len, tonumber(hlf[0])
  end
end

local HLF_SPB = 30

local function spell_check_iter(text, winid)
  local err = ffi.new("Error[1]")
  local w = ffi.C.find_window_by_handle(winid, err)

  local sum = 0

  return function()
    while #text > 0 do
      local len, res = spell_check(w, text)
      local rsum = sum

      sum = sum + len
      text = text:sub(len+1, -1)

      if res == HLF_SPB then
        return rsum, len
      end
    end
  end
end

local function add_extmark(bufnr, lnum, col, len)
  -- TODO: This errors because of an out of bounds column when inserting
  -- newlines. Wrapping in pcall hides the issue.

  local ok, _ = pcall(api.nvim_buf_set_extmark, bufnr, ns, lnum, col, {
    end_line = lnum,
    end_col = col+len,
    hl_group = cfg.hl_id
  })

  if not ok then
    print(('ERROR: Failed to add extmark, lnum=%d pos=%d'):format(lnum, col))
  end
end

local function remove_line_extmarks(bufnr, lnum)
  local es = api.nvim_buf_get_extmarks(bufnr, ns, {lnum,0}, {lnum,-1}, {})
  for _, e in ipairs(es) do
    api.nvim_buf_del_extmark(bufnr, ns, e[1])
  end
end

local hl_queries = {}

local function on_line(_, winid, bufnr, lnum)
  remove_line_extmarks(bufnr, lnum)

  local parser = get_parser(bufnr)

  local hl_query = hl_queries[parser:lang()]

  local line = api.nvim_buf_get_lines(bufnr, lnum, lnum+1, true)[1]

  parser:for_each_tree(function(tstree, _)
    local root_node = tstree:root()
    local root_start_row, _, root_end_row, _ = root_node:range()

    -- Only worry about trees within the line range
    if root_start_row > lnum or root_end_row < lnum then
      return
    end

    for id, node in hl_query:iter_captures(root_node, bufnr, lnum, lnum+1) do
      if vim.tbl_contains(cfg.captures, hl_query.captures[id]) then
        local start_row, start_col, end_row, end_col = node:range()
        if lnum ~= start_row then
          start_col = 0
        end
        if lnum ~= end_row then
          end_col = -1
        end
        local l = line:sub(start_col+1, end_col)
        for col, len in spell_check_iter(l, winid) do
          add_extmark(bufnr, lnum, start_col + col, len)
        end
      end
    end
  end)
end

local function buf_enabled(bufnr)
  if pcall(api.nvim_buf_get_var, bufnr, 'current_syntax') then
    return false
  end
  if not api.nvim_buf_is_loaded(bufnr)
    or api.nvim_buf_get_option(bufnr, 'buftype') ~= '' then
    return false
  end
  if vim.tbl_isempty(cfg.captures) then
    return false
  end
  if not pcall(get_parser, bufnr) then
    return false
  end
  return true
end

local function on_win(_, _, bufnr)
  if not buf_enabled(bufnr) then
    return false
  end
  local parser = get_parser(bufnr)
  local lang = parser:lang()
  if not hl_queries[lang] then
    hl_queries[lang] = query.get_query(lang, "highlights")
  end
  -- FIXME: shouldn't be required. Possibly related to:
  -- https://github.com/nvim-treesitter/nvim-treesitter/issues/1124
  parser:parse()
end

-- Quickly enable 'spell' when running mappings as spell.c explicitly checks for
-- it for much of its functionality.
M._wrap_map = function(key)
  if not vim.wo.spell then
    vim.wo.spell = true
    vim.schedule(function()
      vim.wo.spell = false
    end)
  end
  return key
end

M.nav = function(reverse)
  local row, col = unpack(api.nvim_win_get_cursor(0))
  local e
  if reverse then
    e = api.nvim_buf_get_extmarks(0, ns, {row-1,col-1}, 0, {limit = 1})[1]
  else
    e = api.nvim_buf_get_extmarks(0, ns, {row-1,col+1}, -1, {limit = 1})[1]
  end

  if e then
    local nrow = e[2]
    local ncol = e[3]
    api.nvim_win_set_cursor(0, {nrow+1, ncol})
  end
end

function M.attach(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()

  if not buf_enabled(bufnr) then
    return false
  end

  -- Not all these need to be wrapped but spell.c is pretty messy so wrap them
  -- for good measure.
  for _, key in ipairs{
    'z=', 'zW', 'zg', 'zG', 'zw', 'zuW', 'zug', 'zuG', 'zuw'
  } do
    api.nvim_buf_set_keymap(bufnr, 'n', key,
      string.format([[v:lua.package.loaded.spellsitter._wrap_map('%s')]], key),
      {expr=true}
    )
  end

  api.nvim_buf_set_keymap(bufnr, 'n', ']s', [[<cmd>lua require'spellsitter'.nav()<cr>]], {})
  api.nvim_buf_set_keymap(bufnr, 'n', '[s', [[<cmd>lua require'spellsitter'.nav(true)<cr>]], {})
end

do
  local spell_opt = {}

  function M.mod_spell_opt()
    local bufnr = api.nvim_get_current_buf()
    if not buf_enabled(bufnr) then return end
    spell_opt[bufnr] = vim.wo.spell
    vim.wo.spell = false
  end

  function M.restore_spell_opt()
    local bufnr = api.nvim_get_current_buf()
    if not buf_enabled(bufnr) then return end
    local saved = spell_opt[bufnr]
    if saved ~= nil then
      vim.wo.spell = saved
    end
  end
end

function M.setup(cfg_)
  cfg = cfg_ or {}
  cfg.hl = cfg.hl or 'SpellBad'
  cfg.hl_id = api.nvim_get_hl_id_by_name(cfg.hl)
  cfg.captures = cfg.captures or {'comment'}

  ns = api.nvim_create_namespace('spellsitter')

  setup_spellcheck()
  api.nvim_set_decoration_provider(ns, {
    on_win = on_win,
    on_line = on_line,
  })

  for _, buf in ipairs(api.nvim_list_bufs()) do
    M.attach(buf)
  end

  vim.cmd[[augroup spellsitter]]
  vim.cmd[[autocmd!]]
  vim.cmd[[autocmd BufRead,BufNewFile * lua require("spellsitter").attach()]]
  vim.cmd[[autocmd BufEnter * lua require("spellsitter").mod_spell_opt()]]
  vim.cmd[[autocmd BufLeave * lua require("spellsitter").restore_spell_opt()]]
  vim.cmd[[augroup END']]
end

return M
