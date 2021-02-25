local query = require'vim.treesitter.query'
local get_parser = vim.treesitter.get_parser

local job = require('spellsitter.job').job

local api = vim.api

local M = {}

local cfg

local ns
local hl_query
local cache = {}
local active_bufs = {}
local job_count = 0

local function use_ts()
  return not vim.tbl_isempty(cfg.captures)
end

local function get_col(bufnr, lnum, vcol)
  -- #1: hunspell returns UTF-32 indices whereas nvim extmark  work with UTF-8
  -- indices so we need to convert
  -- TODO: This might have performance impacts so we may want to configure this.
  local l = api.nvim_buf_get_lines(bufnr, lnum, lnum+1, true)[1]
  return vim.str_byteindex(l, vcol)
end

local function add_extmark(bufnr, lnum, result)
  -- TODO: This errors because of an out of bounds column when inserting
  -- newlines. Wrapping in pcall hides the issue.

  local col = get_col(bufnr, lnum, result.pos)

  local ok, _ = pcall(api.nvim_buf_set_extmark, bufnr, ns, lnum, col, {
    end_line = lnum,
    end_col = col+#result.word,
    hl_group = cfg.hl_id,
    ephemeral = true,
  })

  if not ok then
    print(('ERROR: Failed to add extmark, lnum=%d pos=%d'):format(lnum, result.pos))
  end
end

local function get_spellcheck_ranges(bufnr, lnum)
  local r = {}
  local parser = get_parser(bufnr)

  parser:for_each_tree(function(tstree, _)
    local root_node = tstree:root()
    local root_start_row, _, root_end_row, _ = root_node:range()

    -- Only worry about trees within the line range
    if root_start_row > lnum or root_end_row < lnum then
      return
    end

    for id, node in hl_query:iter_captures(root_node, bufnr, lnum, lnum+1) do
      local capture = hl_query.captures[id]
      if vim.tbl_contains(cfg.captures, capture) then
        local start_row, start_col, end_row, end_col = node:range()
        if lnum ~= start_row then
          start_col = 0
        end
        if lnum ~= end_row then
          end_col = -1
        end
        table.insert(r, {start_col, end_col})
      end
    end
  end)

  return r
end

local function process_output_line(line)
  local parts = vim.split(line, '%s+')
  local op = parts[1]
  if op ~= '&' and op ~= '#' then
    return
  end
  local word = parts[2]
  local pos
  if op == '&' then
    pos = tonumber(parts[4]:sub(1, -2))
  elseif op == '#' then
    pos = tonumber(parts[3])
  end
  return {
    word = word,
    pos  = pos
  }
end

local function mask_ranges(line, ranges)
  local r = {}
  for _, range in ipairs(ranges) do
    local scol, ecol = unpack(range)
    local l = string.rep(' ', scol)..line:sub(scol+1, ecol)
    table.insert(r, l)
  end
  return r
end

local function on_line(_, _, bufnr, lnum)
  local bcache = cache[bufnr]

  if bcache[lnum] then
    for _, r in ipairs(bcache[lnum]) do
      add_extmark(bufnr, lnum, r)
    end
    return
  end
  bcache[lnum] = {}

  local lines
  if use_ts() then
    local ranges = get_spellcheck_ranges(bufnr, lnum)
    if vim.tbl_isempty(ranges) then
      return
    end
    local l = api.nvim_buf_get_lines(bufnr, lnum, lnum+1, true)[1]
    lines = mask_ranges(l, ranges)
  else
    lines = api.nvim_buf_get_lines(bufnr, lnum, lnum+1, true)
  end

  job_count = job_count + 1
  job {
    command = cfg.hunspell_cmd,
    args = cfg.hunspell_args,
    input_lines = lines,
    on_stdout = function(out)
      for _, line in ipairs(vim.split(out, '\n')) do
        local r = process_output_line(line)
        if r and cache[bufnr][lnum] then
          table.insert(cache[bufnr][lnum], r)
        end
      end
      vim.schedule(function()
        api.nvim__buf_redraw_range(bufnr, lnum, lnum+1)
      end)
    end
  }
end

local function invalidate_cache_lines(bufnr, first)
  local bcache = cache[bufnr]
  if not bcache then
    return
  end
  for i = first-1, api.nvim_buf_line_count(bufnr) do
    bcache[i] = nil
  end
end

local function attach(winid, cbuf)
  if active_bufs[cbuf] then
    -- Already attached
    return
  end
  active_bufs[cbuf] = true

  -- Disable lagacy vim spellchecker
  api.nvim_win_set_option(winid, 'spell', false)

  api.nvim_buf_attach(cbuf, false, {
    on_lines = function(_, bufnr, _, first)
      invalidate_cache_lines(bufnr, first)
    end,
    on_detach = function(_, bufnr)
      active_bufs[bufnr] = nil
    end
  })
end

local function on_win(_, winid, bufnr)
  if use_ts() then
    local ok, parser = pcall(get_parser, bufnr)
    if not ok then
      return false
    end
    if not hl_query then
      hl_query = query.get_query(parser:lang(), "highlights")
    end
  end

  attach(winid, bufnr)

  if not cache[bufnr] then
    cache[bufnr] = {}
  end
end


local function notify_error(msg)
  api.nvim_notify('Error(spellsitter): '..msg, 4, {})
end

local function test_hunspell(on_success)
  job {
    command = cfg.hunspell_cmd,
    args = cfg.hunspell_args,
    on_stdout = vim.schedule_wrap(function(out)
      local first = vim.split(out, '\n')[1]
      if not vim.startswith(first, 'Hunspell') then
        notify_error('hunspell is not setup correctly')
      else
        on_success()
      end
    end)
  }
end

function M.setup(cfg_)
  cfg = cfg_ or {}
  cfg.hl = cfg.hl or 'SpellBad'
  cfg.hl_id = api.nvim_get_hl_id_by_name(cfg.hl)
  cfg.captures = cfg.captures or {'comment'}
  cfg.hunspell_cmd = cfg.hunspell_cmd or 'hunspell'
  cfg.hunspell_args = cfg.hunspell_args or {}

  test_hunspell(function()
    ns = api.nvim_create_namespace('spellsitter')

    api.nvim_set_decoration_provider(ns, {
      on_win = on_win,
      on_line = on_line;
    })
  end)
end

return M
