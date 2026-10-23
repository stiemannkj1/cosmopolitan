#ifndef COSMOPOLITAN_THIRD_PARTY_LPEG_LPEGPRELOAD_H_
#define COSMOPOLITAN_THIRD_PARTY_LPEG_LPEGPRELOAD_H_
#include "third_party/lua/lua.h"
COSMOPOLITAN_C_START_

int luaopen_lpeg(lua_State *);

/* puts LPeg in package.preload, so that `require "lpeg"` resolves
   without a filesystem lookup.  re.lua, which builds on it, is in the
   zip store at /zip/.lua/re.lua. */
void luaL_preloadlpeg(lua_State *);

COSMOPOLITAN_C_END_
#endif /* COSMOPOLITAN_THIRD_PARTY_LPEG_LPEGPRELOAD_H_ */
