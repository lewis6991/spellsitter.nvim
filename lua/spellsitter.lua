local Job = require('plenary/job')
local query = require'vim.treesitter.query'
local get_parser = require'nvim-treesitter.parsers'.get_parser

local api = vim.api

local M = {}

local ns = api.nvim_create_namespace('spellsitter')
local hl_query
local hl = api.nvim_get_hl_id_by_name('Error')
local cache = {}
local active_bufs = {}

local function del_extmarks(bufnr, lnum)
  local ms = api.nvim_buf_get_extmarks(bufnr, ns, {lnum,0}, {lnum,-1}, {})
  for _, m in ipairs(ms) do
    api.nvim_buf_del_extmark(bufnr, ns, m[1])
  end
end

local function add_extmark(bufnr, lnum, result)
  api.nvim_buf_set_extmark(bufnr, ns, lnum, result.pos, {
    end_line = lnum,
    end_col = result.pos+#result.word,
    hl_group = hl,
    ephemeral = false,
  })
end

local function spellcheck_line(bufnr, lnum)
  local parser = get_parser(bufnr)

  local spellcheck = false
  parser:for_each_tree(function(tstree, _)
    local root_node = tstree:root()
    local root_start_row, _, root_end_row, _ = root_node:range()

    -- Only worry about trees within the line range
    if root_start_row > lnum or root_end_row < lnum then
      return
    end

    local stateiter = hl_query:iter_captures(root_node, bufnr, lnum, root_end_row)
    local capture_id, _ = stateiter()
    local capture = hl_query.captures[capture_id]
    spellcheck = capture == 'comment'
  end)

  return spellcheck
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

local function on_line(_, _, bufnr, lnum)
  if not spellcheck_line(bufnr, lnum) then
    return
  end

  del_extmarks(bufnr, lnum)

  local bcache = cache[bufnr]

  if bcache[lnum] then
    for _, r in ipairs(bcache[lnum]) do
      add_extmark(bufnr, lnum, r)
    end
    return
  end

  local l = api.nvim_buf_get_lines(bufnr, lnum, lnum+1, true)[1]
  Job:new {
    command = 'hunspell',
    writer = {l},
    on_stdout = function(_, line)
      local r = process_output_line(line)
      if not bcache[lnum] then
        bcache[lnum] = {}
      end
      table.insert(bcache[lnum], r)
      if not r then
        return
      end
      vim.schedule(function()
        add_extmark(bufnr, lnum, r)
      end)
    end,
  }:start()
end

local function invalidate_cache_lines(bufnr, first, last)
  local bcache = cache[bufnr]
  if not bcache then
    return
  end
  for i = first, last do
    bcache[i] = nil
  end
end

local function attach(cbuf)
  if active_bufs[cbuf] then
    -- Already attached
    return
  end
  active_bufs[cbuf] = true

  api.nvim_buf_attach(cbuf, false, {
    on_lines = function(_, bufnr, _, first, last)
      invalidate_cache_lines(bufnr, first, last-1)
    end,
    on_detach = function(_, bufnr)
      active_bufs[bufnr] = nil
    end
  })
end

local function on_win(_, _, bufnr)
  local parser = get_parser(bufnr)
  if not parser then
    return false
  end

  attach(bufnr)

  if not hl_query then
    hl_query = query.get_query(parser:lang(), "highlights")
  end

  if not cache[bufnr] then
    cache[bufnr] = {}
  end
end

function M.setup()
  api.nvim_set_decoration_provider(ns, {
    on_start = function(_, tick)
      print('TICK: '..tick)
    end,
    on_win = on_win,
    on_line = on_line;
  })
end

return M
