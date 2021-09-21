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

    typedef unsigned char char_u;

    typedef struct {
      ErrorType type;
      char *msg;
    } Error;

    win_T* find_window_by_handle(int window, Error *err);

    typedef int hlf_T;

    size_t spell_check(
      win_T *wp, const char *ptr, hlf_T *attrp,
      int *capcol, bool docount);

    char_u *did_set_spelllang(win_T *wp);
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

local HLF_SPB
local HLF_SPR
local HLF_SPL

if vim.version().minor == 5 then
  HLF_SPB = 30
  HLF_SPR = 32
  HLF_SPL = 33
else
  HLF_SPB = 32
  HLF_SPR = 34
  HLF_SPL = 35
end

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

      if res == HLF_SPB or res == HLF_SPR or res == HLF_SPL then
        return rsum, len
      end
    end
  end
end

local marks = {}

local function add_extmark(bufnr, lnum, col, len)
  -- TODO: This errors because of an out of bounds column when inserting
  -- newlines. Wrapping in pcall hides the issue.

  local ok, _ = pcall(api.nvim_buf_set_extmark, bufnr, ns, lnum, col, {
    end_line = lnum,
    end_col = col+len,
    hl_group = cfg.hl_id,
    ephemeral = true
  })

  if not ok then
    print(('ERROR: Failed to add extmark, lnum=%d pos=%d'):format(lnum, col))
  end
  local lnum1 = lnum+1
  marks[lnum1] = marks[lnum1] or {}
  marks[lnum1][#marks[lnum1]+1] = {col, col+len}
end

local hl_queries = {}

local function on_line(_, winid, bufnr, lnum)
  marks[lnum+1] = nil

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
        -- This extracts the substring corresponding to the region we want to
        -- spell check from the line. Since this is a lua function on the line
        -- string, we need to convert the 0 indexed values of the columns, to 1
        -- indexed values. Note here that the value of the end column is end
        -- inclusive, so we need to increment it in addition to the start.
        if lnum ~= start_row then
          -- check from the start of this line
          start_col = 1
        else
          start_col = start_col + 1;
        end

        if lnum ~= end_row then
          -- check until the end of this line
          end_col = -1
        else
          end_col = end_col + 1;
        end

        local l = line:sub(start_col, end_col)
        for col, len in spell_check_iter(l, winid) do
          -- start_col is now 1 indexed, so subtract one to make it 0 indexed again
          add_extmark(bufnr, lnum, start_col + col - 1, len)
        end
      end
    end
  end)
end

local excluded_filetypes = {
  rst = true -- Just let the legacy spellchecker apply to the whole buffer
}

local function buf_enabled(bufnr)
  if pcall(api.nvim_buf_get_var, bufnr, 'current_syntax') then
    return false
  end
  if excluded_filetypes[api.nvim_buf_get_option(bufnr, 'filetype')] then
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

local function on_win(_, winid, bufnr)
  if not buf_enabled(bufnr) then
    return false
  end
  local parser = get_parser(bufnr)
  local lang = parser:lang()
  if not hl_queries[lang] then
    hl_queries[lang] = query.get_query(lang, "highlights")
  end

  -- Ensure that the spell language is set for the window. By ensuring this is
  -- set, it prevents an early return from the spelling function that skips
  -- the spell checking.
  local err = ffi.new("Error[1]")
  local w = ffi.C.find_window_by_handle(winid, err)
  local err_spell_lang = ffi.C.did_set_spelllang(w)
  if not err_spell_lang then
      print("ERROR: Failed to set spell languages.", err_spell_lang)
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
  local target = (function()
    -- This api uses a 1 based indexing for the rows (matching the row numbers
    -- within the UI) and a 0 based indexing for columns.
    local row, col = unpack(api.nvim_win_get_cursor(0))

    if reverse then
      -- From the current row number to the start in reverse. Here we are
      -- working with a 1 based indexing for the rows, hence the final value is
      -- 1.
      for i = row, 1, -1 do
        -- Run on_line in case that line hasn't been drawn yet.
        -- Here we are converting the 1 indexed values we have been using to a
        -- 0 indexed value which the on_line function takes.
        on_line(nil, 0, 0, i-1)
        if marks[i] then
          for j = #marks[i], 1, -1 do
            local m = marks[i][j]
            if i ~= row or col > m[1] then
              -- We are using this directly as input to nvim_win_set_cursor,
              -- which uses a 1 based index, so we set this with i rather than
              -- row_num.
              return {i, m[1]}
            end
          end
        end
      end
    else
      -- From the current row number to the end. Here we are working with 1
      -- indexed values, so we go all the way to the last line of the file.
      for i = row, vim.fn.line('$') do
        -- Run on_line in case that line hasn't been drawn yet
        -- Here we are converting the 1 indexed values we have been using to a
        -- 0 indexed value which the on_line function takes.
        on_line(nil, 0, 0, i-1)
        if marks[i] then
          for j = 1, #marks[i] do
            local m = marks[i][j]
            if i ~= row or col < m[1] then
              -- We are using this directly as input to nvim_win_set_cursor,
              -- which uses a 1 based index, so we set this with i rather than
              -- row_num.
              return {i, m[1]}
            end
          end
        end
      end
    end
  end)()

  if target then
    api.nvim_win_set_cursor(0, target)
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
  vim.wo.spell = false
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
    vim.schedule_wrap(M.attach)(buf)
  end

  vim.cmd[[
    augroup spellsitter
    autocmd!
    autocmd BufRead,BufNewFile * lua require("spellsitter").attach()
    augroup END
  ]]
end

return M
