local uv = vim.loop

local M = {}

function M.job(spec)
  local stdin = uv.new_pipe(false)
  local stdout = uv.new_pipe(false)
  local out = ''

  local handle
  handle, _ = uv.spawn(
    spec.command,
    { stdio = { stdin, stdout } },
    function()
      stdout:read_stop()
      stdout:close()
      handle:close()
      spec.on_stdout(out)
    end
  )

  stdout:read_start(function(err, data)
    assert(not err, err)
    if data then
      out = out .. data
    end
  end)

  for _, v in ipairs(spec.input_lines) do
    stdin:write(v)
    stdin:write('\n')
  end
  stdin:close()
end

return M
