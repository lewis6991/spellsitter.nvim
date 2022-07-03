local query = require'vim.treesitter.query'
local get_parser = vim.treesitter.get_parser
local highlighter = vim.treesitter.highlighter
local has_parsers, parsers = pcall(require, 'nvim-treesitter.parsers')

local api = vim.api

local M = {}

local config = {
  enable = true,
  debug = false
}

local ft_to_parsername = {
  tex = 'latex'
}

local function ft_to_parser(ft)
  return has_parsers and parsers.ft_to_lang(ft) or ft_to_parsername[ft] or ft
end

local ns
local attached = {}
local marks = {}
local spellsitter_group = api.nvim_create_augroup("spellsitter_group", { clear = true })

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

local highlights = {
  bad       = 'SpellBad',
  caps      = 'SpellCap',
  rare      = 'SpellRare',
  ['local'] = 'SpellLocal',
}

-- Main spell checking function
local function spell_check(text)
  local sum = 0

  local res = {}
  while #text > 0 do
    local word, type = unpack(vim.fn.spellbadword(text))
    if word == '' then
      -- No bad words
      return res
    end

    -- spellbadword() doesn't tell us the location of the bad word so we need
    -- to find it ourselves.
    local mstart, mend = text:find('%f[%w]'..vim.pesc(word)..'%f[%W]')
    if not mstart then
      -- Fallback, maybe incorrect
      mstart, mend = text:find(vim.pesc(word))
    end

    -- shift out the text up-to the end of the bad word we just found
    text = text:sub(mend+1)
    sum = sum + mend

    local len = mend - mstart + 1

    res[#res+1] = { sum - len, len, type }
  end

  return res
end

-- Cache for highlight_ids
local highlight_ids = {}

local function add_extmark(winid, bufnr, lnum, col, len, highlight)
  -- TODO: This errors because of an out of bounds column when inserting
  -- newlines. Wrapping in pcall hides the issue.

  local cur_lnum, cur_col = unpack(api.nvim_win_get_cursor(winid))
  if cur_lnum-1 == lnum and col <= cur_col and col+len >= cur_col then
    if api.nvim_get_mode().mode == 'i' then
      return
    end
  end

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

  if config.debug and not ok then
    print(('ERROR: Failed to add extmark, lnum=%d pos=%d'):format(lnum, col))
  end

  table.insert(marks[bufnr][lnum+1], {col, col+len})
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
        api.nvim_buf_call(bufnr, function()
          if vim.spell then
            for _, r in ipairs(vim.spell.check(l)) do
              local word, type, col = unpack(r)
              col = col - 1
              -- start_col is now 1 indexed, so subtract one to make it 0 indexed again
              local highlight = config.hl or highlights[type]
              add_extmark(winid, bufnr, lnum, start_col + col - 1, #word, highlight)
            end
          else
            for _, r in ipairs(spell_check(l)) do
              local col, len, type = unpack(r)
              -- start_col is now 1 indexed, so subtract one to make it 0 indexed again
              local highlight = config.hl or highlights[type]
              add_extmark(winid, bufnr, lnum, start_col + col - 1, len, highlight)
            end
          end
        end)
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
  marks[bufnr][lnum+1] = {}

  local ft = vim.bo[bufnr].filetype
  local parser = ft_to_parser(ft)
  get_parser(bufnr, parser):for_each_tree(function(tstree, langtree)
    local root_node = tstree:root()
    local spell_query = get_query(langtree:lang())
    if spell_query then
      spellcheck_tree(winid, bufnr, lnum, root_node, spell_query)
    end
  end)
end

local function enabled(bufnr, winid)
  if not vim.wo[winid].spell then
    return false
  end
  if not highlighter.active[bufnr] then
    return false
  end
  local ft = vim.bo[bufnr].filetype
  if config.enable ~= true and not vim.tbl_contains(config.enable, ft) then
    return false
  end
  local parser = ft_to_parser(ft)
  if not pcall(get_parser, bufnr, parser) then
    return false
  end
  return true
end

local get_nav_target = function(bufnr, reverse)
  -- This api uses a 1 based indexing for the rows (matching the row numbers
  -- within the UI) and a 0 based indexing for columns.
  local row, col = unpack(api.nvim_win_get_cursor(0))

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
  local winid = api.nvim_get_current_win()

  if not enabled(bufnr, winid) then
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

local try_attach = function(bufnr)
  if attached[bufnr] then
    -- Already attached
    return
  end

  attached[bufnr] = true
  marks[bufnr] = {}

  api.nvim_buf_attach(bufnr, false, {
    on_detach = function(_, buf)
      attached[buf] = nil
      marks[buf] = nil
    end
  })

  if vim.fn.hasmapto(']s', 'n') == 0 then
    api.nvim_buf_set_keymap(bufnr, 'n', ']s', [[<cmd>lua require'spellsitter'.nav()<cr>]], {})
  end

  if vim.fn.hasmapto('[s', 'n') == 0 then
    api.nvim_buf_set_keymap(bufnr, 'n', '[s', [[<cmd>lua require'spellsitter'.nav(true)<cr>]], {})
  end
end

local function on_win(_, winid, bufnr)
  if not enabled(bufnr, winid) then
    return false
  end

  -- HACK ALERT: To prevent the internal spellchecker from spellchecking, we
  -- need to define a 'Spell' syntax group which contains nothing.
  api.nvim_win_call(winid, function()
    if vim.fn.has('syntax_items') == 0 then
      vim.cmd'syntax cluster Spell contains=NONE'
    end
  end)

  try_attach(bufnr)
end

local function create_disable_autocmd()
  if type(config.disable) == "table" then
    api.nvim_create_autocmd("FileType", {
      pattern = config.disable,
      command = "setlocal nospell",
      group = spellsitter_group,
    })
  elseif type(config.disable) == "function" then
    api.nvim_create_autocmd("FileType", {
      pattern = "*",
      callback = function()
        local bufnr = api.nvim_get_current_buf()
        local ft = api.nvim_buf_get_option(bufnr, 'filetype')
        if config.disable(ft, bufnr) then
          vim.cmd("setlocal nospell")
        end
      end,
      group = spellsitter_group,
    })
  else
    if config.debug then
      print("ERROR: disable option expect either a lua table or function")
    end
  end
end

function M.setup(user_config)
  config = vim.tbl_deep_extend('force', config, user_config or {})

  if config.disable then
    create_disable_autocmd()
  end

  ns = api.nvim_create_namespace('spellsitter')

  api.nvim_set_decoration_provider(ns, {
    on_win = on_win,
    on_line = on_line,
  })
end

return M
