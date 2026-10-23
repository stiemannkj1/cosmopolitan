#ifndef COSMOPOLITAN_THIRD_PARTY_LFS_LFSPRELOAD_H_
#define COSMOPOLITAN_THIRD_PARTY_LFS_LFSPRELOAD_H_
#include "third_party/lua/lua.h"
COSMOPOLITAN_C_START_

/* puts LuaFileSystem in package.preload, so that `require "lfs"`
   resolves without a filesystem lookup. */
void luaL_preloadlfs(lua_State *);

COSMOPOLITAN_C_END_
#endif /* COSMOPOLITAN_THIRD_PARTY_LFS_LFSPRELOAD_H_ */
