local function spell_check_iter(text, _)
  local sum = 0

  return function()
    while #text > 0 do
      local word, _ = unpack(vim.fn.spellbadword(text))
      if word == '' then
        -- No bad words
        return
      end

      -- spellbadword() doesn't tell us the location of the bad word so we need
      -- to find it ourselves.
      local mstart, mend = text:find('%f[%w]'..word..'%f[%W]')
      if not mstart then
        -- happens when vim disagrees with the above lua pattern on what a word
        -- boundary is
        return
      end

      -- shift out the text up-to the end of the bad word we just found
      text = text:sub(mend+1)
      sum = sum + mend

      local len = mend - mstart + 1

      return sum - len, len
    end
  end
end

return spell_check_iter
