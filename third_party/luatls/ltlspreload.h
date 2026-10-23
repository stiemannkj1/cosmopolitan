#ifndef COSMOPOLITAN_THIRD_PARTY_LUATLS_LTLSPRELOAD_H_
#define COSMOPOLITAN_THIRD_PARTY_LUATLS_LTLSPRELOAD_H_
#include "third_party/lua/lua.h"
COSMOPOLITAN_C_START_

int luaopen__cosmo_tls(lua_State *);

/* adds the engine constructors to the module table on top of the stack */
void LuaTlsEngineInit(lua_State *);

/* puts the native half of the TLS support in package.preload under the
   name "_cosmo_tls".  The luaossl-shaped modules lua-http requires are
   pure Lua on top of it, in the zip store under /zip/.lua/openssl/. */
void luaL_preloadtls(lua_State *);

COSMOPOLITAN_C_END_
#endif /* COSMOPOLITAN_THIRD_PARTY_LUATLS_LTLSPRELOAD_H_ */
