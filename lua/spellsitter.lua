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
    hl_group = cfg.hl_id,
    ephemeral = true,
  })

  if not ok then
    print(('ERROR: Failed to add extmark, lnum=%d pos=%d'):format(lnum, col))
  end
end

local hl_queries = {}

local function on_line(_, winid, bufnr, lnum)
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

local function on_win(_, _, bufnr)
  if not api.nvim_buf_is_loaded(bufnr)
    or api.nvim_buf_get_option(bufnr, 'buftype') ~= '' then
    return false
  end
  if vim.tbl_isempty(cfg.captures) then
    return false
  end
  local ok, parser = pcall(get_parser, bufnr)
  if not ok  then
    return false
  end
  local lang = parser:lang()
  if not hl_queries[lang] then
    hl_queries[lang] = query.get_query(lang, "highlights")
  end
  -- FIXME: shouldn't be required. Possibly related to:
  -- https://github.com/nvim-treesitter/nvim-treesitter/issues/1124
  parser:parse()
  vim.wo.spell = false
end

-- Quickly enable 'spell' when running mappings as spell.c explicitly checks for
-- it for much of its functionality.
M._wrap_map = function(key)
  vim.wo.spell = true
  vim.schedule(function()
    vim.wo.spell = false
  end)
  return key
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

  -- Not all these need to be wrapped but spell.c is pretty messy so wrap them
  -- for good measure.
  for _, key in ipairs{
    'z=', 'zW', 'zg', 'zG', 'zw', 'zuW', 'zug', 'zuG', 'zuw'
  } do
    vim.api.nvim_set_keymap('n', key,
      string.format([[v:lua.package.loaded.spellsitter._wrap_map('%s')]], key),
      {expr=true}
    )
  end

  -- TODO: implement [s, ]s, ]S and [S
end

-- M.list_marks = function()
--   print(vim.inspect(api.nvim_buf_get_extmarks(0, ns, 0, -1, {})))
-- end

return M
