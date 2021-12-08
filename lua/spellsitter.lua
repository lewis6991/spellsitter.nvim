local query = require'vim.treesitter.query'
local get_parser = vim.treesitter.get_parser

local api = vim.api

local M = {}

local valid_spellcheckers = {'vimfn', 'ffi'}

local config = {
  enable       = true,
  spellchecker = 'vimfn'
}

local ns

local marks = {}

pcall(require, 'nvim-treesitter.query_predicates')

if not vim.tbl_contains(query.list_predicates(), 'has-parent?') then
  -- Defined in nvim-treesitter so define it here if nvim-treesitter is not
  -- installed
  query.add_predicate("has-parent?", function (match, _, _, pred)
    local node = match[pred[2]]:parent()
    local ancestor_types = { unpack(pred, 3) }
    return vim.tbl_contains(ancestor_types, node:type())
  end)
end

-- Main spell checking function
local spell_check_iter

-- Cache for highlight_ids
local highlight_ids = {}

local function add_extmark(bufnr, lnum, col, len, highlight)
  -- TODO: This errors because of an out of bounds column when inserting
  -- newlines. Wrapping in pcall hides the issue.

  local hl_id = highlight_ids[highlight]
  if not hl_id then
    hl_id = api.nvim_get_hl_id_by_name(highlight)
    highlight_ids[highlight] = hl_id
  end

  local ok, _ = pcall(api.nvim_buf_set_extmark, bufnr, ns, lnum, col, {
    end_line = lnum,
    end_col = col+len,
    hl_group = hl_id,
    ephemeral = true
  })

  if not ok then
    print(('ERROR: Failed to add extmark, lnum=%d pos=%d'):format(lnum, col))
  end
  local lnum1 = lnum+1
  marks[bufnr] = marks[bufnr] or {}
  marks[bufnr][lnum1] = marks[bufnr][lnum1] or {}
  local lbmarks = marks[bufnr][lnum1]
  lbmarks[#lbmarks+1] = {col, col+len}
end

local function spellcheck_tree(winid, bufnr, lnum, root_node, spell_query)
  local root_start_row, _, root_end_row, _ = root_node:range()

  -- Only worry about trees within the line range
  if root_start_row > lnum or root_end_row < lnum then
    return
  end

  for id, node, metadata in spell_query:iter_captures(root_node, bufnr, lnum, lnum+1) do
    if vim.tbl_contains({'spell', 'comment'}, spell_query.captures[id]) then
      local range = metadata.content and metadata.content[1] or {node:range()}
      local start_row, start_col, end_row, end_col = unpack(range)
      if lnum >= start_row and lnum <= end_row then
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

        local line = api.nvim_buf_get_lines(bufnr, lnum, lnum+1, true)[1]
        local l = line:sub(start_col, end_col)
        for col, len, type in spell_check_iter(l, winid) do
          -- start_col is now 1 indexed, so subtract one to make it 0 indexed again
          local highlight = config.hl or ({
            bad       = 'SpellBad',
            caps      = 'SpellCap',
            rare      = 'SpellRare',
            ['local'] = 'SpellLocal',
          })[type]
          add_extmark(bufnr, lnum, start_col + col - 1, len, highlight)
        end
      end
    end
  end
end

local function get_query0(lang)
  -- Use the spell query if there is one available otherwise just
  -- spellcheck comments.
  local lang_query = query.get_query(lang, 'spell')

  if lang_query then
    return lang_query
  end

  -- First fallback is to use the comment nodes, if defined
  local ok, ret = pcall(query.parse_query, lang, "(comment)  @spell")
  if ok then
    return ret
  end

  -- Second fallback is to use comments from the highlight captures
  return query.get_query(lang, 'highlights')
end

local spell_queries = {}

local function get_query(lang)
  if not spell_queries[lang] then
    spell_queries[lang] = get_query0(lang)
  end
  return spell_queries[lang]
end

local function on_line(_, winid, bufnr, lnum)
  marks[bufnr] = marks[bufnr] or {}
  marks[bufnr][lnum+1] = nil

  get_parser(bufnr):for_each_tree(function(tstree, langtree)
    local root_node = tstree:root()
    local spell_query = get_query(langtree:lang())
    if spell_query then
      spellcheck_tree(winid, bufnr, lnum, root_node, spell_query)
    end
  end)
end

local function buf_enabled(bufnr)
  if not api.nvim_buf_is_loaded(bufnr) then
    return false
  end
  if not vim.treesitter.highlighter.active[bufnr] then
    return false
  end
  local ft = vim.bo[bufnr].filetype
  if config.enable ~= true and not vim.tbl_contains(config.enable, ft) then
    return false
  end
  if not api.nvim_buf_is_loaded(bufnr)
    or api.nvim_buf_get_option(bufnr, 'buftype') ~= '' then
    return false
  end
  if not pcall(get_parser, bufnr) then
    return false
  end
  return true
end

local function on_win(_, winid, bufnr)
  if not vim.wo[winid].spell then
    return false
  end

  if not buf_enabled(bufnr) then
    return false
  end

  -- FIXME: shouldn't be required. Possibly related to:
  -- https://github.com/nvim-treesitter/nvim-treesitter/issues/1124
  get_parser(bufnr):parse()
end

local get_nav_target = function(bufnr, reverse)
  -- This api uses a 1 based indexing for the rows (matching the row numbers
  -- within the UI) and a 0 based indexing for columns.
  local row, col = unpack(api.nvim_win_get_cursor(0))

  marks[bufnr] = marks[bufnr] or {}

  local bmarks = marks[bufnr]

  if reverse then
    -- From the current row number to the start in reverse. Here we are
    -- working with a 1 based indexing for the rows, hence the final value is
    -- 1.
    for i = row, 1, -1 do
      -- Run on_line in case that line hasn't been drawn yet.
      -- Here we are converting the 1 indexed values we have been using to a
      -- 0 indexed value which the on_line function takes.
      on_line(nil, 0, bufnr, i-1)
      if bmarks[i] then
        for j = #bmarks[i], 1, -1 do
          local m = bmarks[i][j]
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
    for i = row, api.nvim_buf_line_count(bufnr) do
      -- Run on_line in case that line hasn't been drawn yet
      -- Here we are converting the 1 indexed values we have been using to a
      -- 0 indexed value which the on_line function takes.
      on_line(nil, 0, bufnr, i-1)
      if bmarks[i] then
        for j = 1, #bmarks[i] do
          local m = bmarks[i][j]
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
end

M.nav = function(reverse)
  local bufnr = api.nvim_get_current_buf()

  if not buf_enabled(bufnr) then
    if reverse then
      vim.cmd'normal! [s'
    else
      vim.cmd'normal! ]s'
    end
    return
  end

  local target = get_nav_target(bufnr, reverse)
  if target then
    vim.cmd [[ normal! m' ]] -- add current cursor position to the jump list
    api.nvim_win_set_cursor(0, target)
  end
end

M.attach = function(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()

  if not buf_enabled(bufnr) then
    return false
  end

  if vim.fn.hasmapto(']s', 'n') == 0 then
    api.nvim_buf_set_keymap(bufnr, 'n', ']s', [[<cmd>lua require'spellsitter'.nav()<cr>]], {})
  end

  if vim.fn.hasmapto('[s', 'n') == 0 then
    api.nvim_buf_set_keymap(bufnr, 'n', '[s', [[<cmd>lua require'spellsitter'.nav(true)<cr>]], {})
  end

  -- HACK ALERT: To prevent the internal spellchecker from spellchecking, we
  -- need to define a 'Spell' syntax group which contains nothing.
  --
  -- For whatever reason 'syntax clear' doesn't remove this group so we are safe
  -- from treesitter reloading the buffer.
  vim.schedule(function()
    api.nvim_buf_call(bufnr, function()
      vim.cmd'syntax cluster Spell contains=NONE'
    end)
  end)
end

function M.setup(user_config)
  config = vim.tbl_deep_extend('force', config, user_config or {})

  if not vim.tbl_contains(valid_spellcheckers, config.spellchecker) then
    error(string.format('spellsitter: %s is not a valid spellchecker. Must be one of: %s',
      config.spellchecker, table.concat(valid_spellcheckers, ', ')))
  end

  ns = api.nvim_create_namespace('spellsitter')

  spell_check_iter = require('spellsitter.spellcheck.'..config.spellchecker)

  api.nvim_set_decoration_provider(ns, {
    on_win = on_win,
    on_line = on_line,
  })

  for _, buf in ipairs(api.nvim_list_bufs()) do
    M.attach(buf)
  end

  vim.cmd[[
    augroup spellsitter
    autocmd!
    autocmd FileType * lua _G.package.loaded.spellsitter.attach()
    augroup END
  ]]
end

return M
