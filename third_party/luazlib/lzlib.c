/*-*- mode:c;indent-tabs-mode:nil;c-basic-offset:2;tab-width:8;coding:utf-8 -*-│
│ vi: set et ft=c ts=2 sts=2 sw=2 fenc=utf-8                               :vi │
╚──────────────────────────────────────────────────────────────────────────────╝
│                                                                              │
│  A lua-zlib compatible binding over the zlib already in third_party.         │
│                                                                              │
│  Only the part lua-http's http/zlib.lua uses is implemented, which is        │
│  _VERSION, inflate() and deflate().  Both return a stream closure that       │
│  takes a chunk and answers the bytes produced so far plus whether the        │
│  stream has ended, which is the lua-zlib calling convention.                 │
│                                                                              │
╚─────────────────────────────────────────────────────────────────────────────*/
#include "third_party/luazlib/lzlibpreload.h"
#include "libc/str/str.h"
#include "third_party/lua/lauxlib.h"
#include "third_party/lua/lua.h"
#include "third_party/zlib/zlib.h"

__static_yoink("luazlib_notice");

#define CHUNK 16384

struct LuaZStream {
  z_stream z;
  char deflating;
  char finished;
  char closed;
};

static struct LuaZStream *checkstream(lua_State *L) {
  struct LuaZStream *s = lua_touserdata(L, lua_upvalueindex(1));
  if (!s || s->closed)
    luaL_error(L, "zlib stream is closed");
  return s;
}

static int LuaZlibStreamGc(lua_State *L) {
  struct LuaZStream *s = lua_touserdata(L, 1);
  if (s && !s->closed) {
    if (s->deflating) {
      deflateEnd(&s->z);
    } else {
      inflateEnd(&s->z);
    }
    s->closed = 1;
  }
  return 0;
}

/* stream(chunk [, flush]) -> output, eof */
static int LuaZlibStreamCall(lua_State *L) {
  int rc;
  size_t len = 0;
  const char *chunk;
  luaL_Buffer b;
  char out[CHUNK];
  int flush;
  struct LuaZStream *s = checkstream(L);
  chunk = lua_isnoneornil(L, 1) ? "" : luaL_checklstring(L, 1, &len);
  if (s->deflating) {
    /* lua-zlib spells the flush modes as strings */
    const char *f = luaL_optstring(L, 2, "none");
    if (!strcmp(f, "finish")) {
      flush = Z_FINISH;
    } else if (!strcmp(f, "sync")) {
      flush = Z_SYNC_FLUSH;
    } else if (!strcmp(f, "full")) {
      flush = Z_FULL_FLUSH;
    } else {
      flush = Z_NO_FLUSH;
    }
  } else {
    flush = Z_SYNC_FLUSH;
  }
  if (s->finished) {
    lua_pushliteral(L, "");
    lua_pushboolean(L, 1);
    return 2;
  }
  luaL_buffinit(L, &b);
  s->z.next_in = (Bytef *)chunk;
  s->z.avail_in = len;
  do {
    s->z.next_out = (Bytef *)out;
    s->z.avail_out = sizeof(out);
    rc = s->deflating ? deflate(&s->z, flush) : inflate(&s->z, flush);
    if (rc == Z_STREAM_END) {
      s->finished = 1;
    } else if (rc == Z_BUF_ERROR) {
      /* no progress possible, which is not an error for a flush that
         had nothing left to do */
      break;
    } else if (rc != Z_OK) {
      luaL_error(L, "zlib: %s", s->z.msg ? s->z.msg : "stream error");
    }
    luaL_addlstring(&b, out, sizeof(out) - s->z.avail_out);
  } while (!s->finished && (s->z.avail_in > 0 || s->z.avail_out == 0 ||
                            flush == Z_FINISH));
  luaL_pushresult(&b);
  lua_pushboolean(L, s->finished);
  return 2;
}

static int LuaZlibNewStream(lua_State *L, int deflating, int windowbits,
                            int level) {
  int rc;
  struct LuaZStream *s = lua_newuserdatauv(L, sizeof(*s), 0);
  bzero(s, sizeof(*s));
  s->deflating = deflating;
  if (deflating) {
    rc = deflateInit2(&s->z, level, Z_DEFLATED, windowbits, 8,
                      Z_DEFAULT_STRATEGY);
  } else {
    rc = inflateInit2(&s->z, windowbits);
  }
  if (rc != Z_OK)
    return luaL_error(L, "zlib: could not initialize stream");
  if (luaL_newmetatable(L, "cosmo.zlib.stream")) {
    lua_pushcfunction(L, LuaZlibStreamGc);
    lua_setfield(L, -2, "__gc");
  }
  lua_setmetatable(L, -2);
  lua_pushcclosure(L, LuaZlibStreamCall, 1);
  return 1;
}

/* zlib.inflate([windowBits]) -- defaults to automatic zlib/gzip detection */
static int LuaZlibInflate(lua_State *L) {
  int windowbits = (int)luaL_optinteger(L, 1, MAX_WBITS + 32);
  return LuaZlibNewStream(L, 0, windowbits, 0);
}

/* zlib.deflate([level], [method], [windowBits])

   lua-zlib defaults windowBits to MAX_WBITS, which is the raw zlib
   wrapper.  this defaults to MAX_WBITS+16, which is gzip, because the
   only caller is lua-http and the only thing it does with the output is
   serve it as `transfer-encoding: gzip`.  pass windowBits explicitly for
   the other framings. */
static int LuaZlibDeflate(lua_State *L) {
  int level = (int)luaL_optinteger(L, 1, Z_DEFAULT_COMPRESSION);
  int windowbits = (int)luaL_optinteger(L, 3, MAX_WBITS + 16);
  return LuaZlibNewStream(L, 1, windowbits, level);
}

static int LuaZlibVersion(lua_State *L) {
  lua_pushstring(L, zlibVersion());
  return 1;
}

static const luaL_Reg kLuaZlib[] = {
    {"inflate", LuaZlibInflate},  //
    {"deflate", LuaZlibDeflate},  //
    {"version", LuaZlibVersion},  //
    {0},                          //
};

int luaopen_zlib(lua_State *L) {
  luaL_newlib(L, kLuaZlib);
  /* http/zlib.lua switches on this prefix to pick its calling
     convention, so it has to keep saying lua-zlib */
  lua_pushliteral(L, "lua-zlib 1.2 (cosmopolitan, over zlib " ZLIB_VERSION ")");
  lua_setfield(L, -2, "_VERSION");
  return 1;
}

void luaL_preloadzlib(lua_State *L) {
  luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
  lua_pushcfunction(L, luaopen_zlib);
  lua_setfield(L, -2, "zlib");
  lua_pop(L, 1); /* remove PRELOAD table */
}
