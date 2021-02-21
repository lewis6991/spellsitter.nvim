local Job = require('plenary/job')
local query = require'vim.treesitter.query'
local ts = require'vim.treesitter'

local api = vim.api

local M = {}

local ns = api.nvim_create_namespace('spellsitter')
local hl_query
local hl = api.nvim_get_hl_id_by_name('Error')
local changedtick = 0

local function del_extmarks_for_line(bufnr, lnum)
  local ms = api.nvim_buf_get_extmarks(bufnr, ns, {lnum,0}, {lnum,-1}, {})
  for _, m in ipairs(ms) do
    api.nvim_buf_del_extmark(bufnr, ns, m[1])
  end
end

local function spellcheck_line(bufnr, lnum)
  local lang = api.nvim_buf_get_option(bufnr, "ft")
  local parser = ts.get_parser(bufnr, lang)
  if not parser then
    return false
  end

  if not hl_query then
    hl_query = query.get_query(parser:lang(), "highlights")
  end

  local spellcheck = false
  parser:for_each_tree(function(tstree, _)
    local root_node = tstree:root()
    local root_start_row, _, root_end_row, _ = root_node:range()

    -- Only worry about trees within the line range
    if root_start_row > lnum or root_end_row < lnum then
      return
    end

    local stateiter = hl_query:iter_captures(root_node, bufnr, lnum, root_end_row )
    local capture_id, _ = stateiter()
    local capture = hl_query.captures[capture_id]
    spellcheck = capture == 'comment'
  end)

  return spellcheck
end

local function on_line(_, _, bufnr, lnum)
  if not spellcheck_line(bufnr, lnum) then
    return
  end

  del_extmarks_for_line(bufnr, lnum)

  local l = api.nvim_buf_get_lines(bufnr, lnum, lnum+1, true)[1]

  local results = {}
  Job:new {
    command = 'hunspell',
    writer = {l},
    on_stdout = function(_, line)
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
      table.insert(results, {
        word = word,
        pos = pos
      })
      vim.schedule(function()
        api.nvim_buf_set_extmark(bufnr, ns, lnum, pos, {
          end_line = lnum,
          end_col = pos+#word,
          hl_group = hl,
          ephemeral = false,
        })
      end)
    end,
  }:start()

end

function M.setup()
  api.nvim_set_decoration_provider(ns, {
    on_win = function(_, _, bufnr)
      local changedtick0 = api.nvim_buf_get_var(bufnr, 'changedtick')
      if changedtick == changedtick0 then
        return false
      end
      changedtick = changedtick0
      return true
    end;
    on_line = on_line;
  })
end

return M
