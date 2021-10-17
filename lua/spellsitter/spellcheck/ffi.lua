local ffi = require("ffi")

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

local spell_check = function(win_handle, text)
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

local err = ffi.new("Error[1]")

local function on_win(_, winid, _)
  -- Ensure that the spell language is set for the window. By ensuring this is
  -- set, it prevents an early return from the spelling function that skips
  -- the spell checking.
  local w = ffi.C.find_window_by_handle(winid, err)
  local err_spell_lang = ffi.C.did_set_spelllang(w)
  if not err_spell_lang then
      print("ERROR: Failed to set spell languages.", err_spell_lang)
  end
end

local ns = vim.api.nvim_create_namespace('spellsitter.spellcheck.ffi')
vim.api.nvim_set_decoration_provider(ns, {
  on_win = on_win
})

local function spell_check_iter(text, winid)
  local w = ffi.C.find_window_by_handle(winid, err)

  local sum = 0

  return function()
    while #text > 0 do
      local len, res = spell_check(w, text)

      text = text:sub(len+1, -1)
      sum = sum + len

      if res == HLF_SPB or res == HLF_SPR or res == HLF_SPL then
        return sum - len, len
      end
    end
  end
end

return spell_check_iter
