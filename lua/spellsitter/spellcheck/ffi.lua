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

local capcol_ptr = ffi.new("int[1]", -1)
local hlf = ffi.new("hlf_T[1]", 0)

local spell_check = function(win_handle, text, capcol)
  hlf[0] = 0
  capcol_ptr[0] = capcol
  local len = tonumber(ffi.C.spell_check(win_handle, text, hlf, capcol_ptr, false))
  return len, tonumber(hlf[0]), tonumber(capcol_ptr[0])
end

local HLF_SPB -- SpellBad
local HLF_SPC -- SpellCap
local HLF_SPR -- SpellRare
local HLF_SPL -- SpellLocal

if vim.version().minor == 5 then
  HLF_SPB = 30
  HLF_SPC = 31
  HLF_SPR = 32
  HLF_SPL = 33
else
  HLF_SPB = 32
  HLF_SPC = 33
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
  local capcol = 0

  return function()
    local len, res
    while #text > 0 do
      len, res, capcol = spell_check(w, text, capcol)
      if capcol > 0 then
        capcol = capcol - len
      end

      text = text:sub(len+1, -1)
      sum = sum + len

      local type = ({
        [HLF_SPB] = 'bad',
        [HLF_SPC] = 'caps',
        [HLF_SPR] = 'rare',
        [HLF_SPL] = 'local'
      })[res]

      if type then
        return sum - len, len, type
      end
    end
  end
end

return spell_check_iter
