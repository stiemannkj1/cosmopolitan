#ifndef COSMOPOLITAN_THIRD_PARTY_LUAZLIB_LZLIBPRELOAD_H_
#define COSMOPOLITAN_THIRD_PARTY_LUAZLIB_LZLIBPRELOAD_H_
#include "third_party/lua/lua.h"
COSMOPOLITAN_C_START_

int luaopen_zlib(lua_State *);

/* puts the lua-zlib compatible binding in package.preload under the
   name "zlib", which is what lua-http's http/zlib.lua requires. */
void luaL_preloadzlib(lua_State *);

COSMOPOLITAN_C_END_
#endif /* COSMOPOLITAN_THIRD_PARTY_LUAZLIB_LZLIBPRELOAD_H_ */
