local query = require'vim.treesitter.query'
local get_parser = vim.treesitter.get_parser

local api = vim.api

local M = {}

local cfg

local ns
local hl_query
local cache = {}
local active_bufs = {}

local ffi = require("ffi")
ffi.cdef[[
typedef void win_T;

win_T* find_window_by_handle(int window, int err);

typedef int hlf_T;

size_t spell_check(
    win_T *wp, const char *ptr, hlf_T *attrp,
    int *capcol, bool docount);
]]

local HLF_SPB = 30

local function spell_check(text)
  local w = ffi.C.find_window_by_handle(0, 0)
  local capcol = ffi.new("int[1]", -1)
  local hlf = ffi.new("hlf_T[1]", 0)
  local sum = 0

  return function()
    while #text > 0 do
      hlf[0] = 0

      local len = tonumber(ffi.C.spell_check(w, text, hlf, capcol, false))
      local rsum = sum

      sum = sum + len
      text = text:sub(len+1, -1)

      if tonumber(hlf[0]) == HLF_SPB then
        return rsum, len
      end
    end
  end
end

local function use_ts()
  return not vim.tbl_isempty(cfg.captures)
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

  for _, l in ipairs(lines) do
    for col, len in spell_check(l) do
      add_extmark(bufnr, lnum, col, len)
    end
  end
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

function M.setup(cfg_)
  cfg = cfg_ or {}
  cfg.hl = cfg.hl or 'SpellBad'
  cfg.hl_id = api.nvim_get_hl_id_by_name(cfg.hl)
  cfg.captures = cfg.captures or {'comment'}

  ns = api.nvim_create_namespace('spellsitter')

  api.nvim_set_decoration_provider(ns, {
    on_win = on_win,
    on_line = on_line;
  })
end

return M
