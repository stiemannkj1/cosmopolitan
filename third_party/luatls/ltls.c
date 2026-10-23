/*-*- mode:c;indent-tabs-mode:nil;c-basic-offset:2;tab-width:8;coding:utf-8 -*-│
│ vi: set et ft=c ts=2 sts=2 sw=2 fenc=utf-8                               :vi │
╚──────────────────────────────────────────────────────────────────────────────╝
│                                                                              │
│  The native half of the TLS support lua-http needs, over the mbedtls         │
│  already in third_party.  Deliberately small: it does randomness,            │
│  message digests, and a non-blocking TLS engine driven by whoever owns       │
│  the poll loop.  Everything that has to look like luaossl is shaped in       │
│  Lua, in third_party/luatls/.lua/openssl/.                                   │
│                                                                              │
╚─────────────────────────────────────────────────────────────────────────────*/
#include "third_party/luatls/ltlspreload.h"
#include "libc/stdio/rand.h"
#include "libc/str/str.h"
#include "third_party/lua/lauxlib.h"
#include "third_party/lua/lua.h"
#include "third_party/mbedtls/sha1.h"
#include "third_party/mbedtls/sha256.h"

__static_yoink("luatls_notice");

/* tls.rand(n) -> string of n random bytes */
static int LuaTlsRand(lua_State *L) {
  char tmp[256];
  luaL_Buffer b;
  lua_Integer n = luaL_checkinteger(L, 1);
  if (n < 0 || n > (lua_Integer)(1 << 20))
    return luaL_error(L, "unreasonable number of random bytes");
  luaL_buffinit(L, &b);
  while (n > 0) {
    ssize_t got;
    size_t want = n < (lua_Integer)sizeof(tmp) ? (size_t)n : sizeof(tmp);
    got = getrandom(tmp, want, 0);
    if (got < 1)
      return luaL_error(L, "getrandom failed");
    luaL_addlstring(&b, tmp, got);
    n -= got;
  }
  luaL_pushresult(&b);
  return 1;
}

/* tls.digest(algorithm, data) -> raw digest bytes */
static int LuaTlsDigest(lua_State *L) {
  size_t len;
  unsigned char out[32];
  const char *alg = luaL_checkstring(L, 1);
  const char *data = luaL_checklstring(L, 2, &len);
  if (!strcasecmp(alg, "sha1")) {
    if (mbedtls_sha1_ret(data, len, out))
      return luaL_error(L, "sha1 failed");
    lua_pushlstring(L, (char *)out, 20);
    return 1;
  } else if (!strcasecmp(alg, "sha256")) {
    if (mbedtls_sha256_ret(data, len, out, 0))
      return luaL_error(L, "sha256 failed");
    lua_pushlstring(L, (char *)out, 32);
    return 1;
  }
  return luaL_error(L, "unsupported digest %s", alg);
}

static const luaL_Reg kLuaTls[] = {
    {"rand", LuaTlsRand},      //
    {"digest", LuaTlsDigest},  //
    {0},                       //
};

int luaopen__cosmo_tls(lua_State *L) {
  luaL_newlib(L, kLuaTls);
  LuaTlsEngineInit(L); /* adds the TLS engine to the table on the stack */
  return 1;
}

void luaL_preloadtls(lua_State *L) {
  luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
  lua_pushcfunction(L, luaopen__cosmo_tls);
  lua_setfield(L, -2, "_cosmo_tls");
  lua_pop(L, 1); /* remove PRELOAD table */
}
