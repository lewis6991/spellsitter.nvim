local uv = vim.loop

local M = {}

function M.job(spec)
  spec.input_lines = spec.input_lines or {}
  local stdin = uv.new_pipe(false)
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)
  local out = ''

  local handle
  handle, _ = uv.spawn(
    spec.command,
    {
      args = spec.args,
      stdio = { stdin, stdout, stderr }
    },
    function()
      stdout:read_stop()
      stdout:close()
      stderr:close()
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

  stderr:read_start(function(_, data)
    if data then
      local args = table.concat(spec.args, ' ')
      print(string.format("Error running command: '%s %s'", spec.command, args))
      print('stderr: '..vim.inspect(data))
    end
  end)

  for _, v in ipairs(spec.input_lines) do
    stdin:write(v)
    stdin:write('\n')
  end
  stdin:close()
end

return M
