/*-*- mode:c;indent-tabs-mode:nil;c-basic-offset:2;tab-width:8;coding:utf-8 -*-│
│ vi: set et ft=c ts=2 sts=2 sw=2 fenc=utf-8                               :vi │
╚──────────────────────────────────────────────────────────────────────────────╝
│                                                                              │
│  A non-blocking TLS engine over mbedtls.                                     │
│                                                                              │
│  It owns no event loop.  Every call answers either a result or one of        │
│  the strings "want_read" and "want_write", and whoever owns the poll         │
│  loop, which here is cqueues.socket, waits and calls again.  That is         │
│  what lets one TLS connection live inside a coroutine scheduler without      │
│  blocking the others.                                                        │
│                                                                              │
╚─────────────────────────────────────────────────────────────────────────────*/
#include "libc/calls/calls.h"
#include "libc/errno.h"
#include "libc/mem/mem.h"
#include "libc/sock/sock.h"
#include "libc/str/str.h"
#include "libc/sysv/consts/msg.h"
#include "net/https/https.h"
#include "third_party/lua/lauxlib.h"
#include "third_party/lua/lua.h"
#include "third_party/luatls/ltlspreload.h"
#include "third_party/mbedtls/ctr_drbg.h"
#include "third_party/mbedtls/error.h"
#include "third_party/mbedtls/net_sockets.h"
#include "third_party/mbedtls/ssl.h"
#include "third_party/mbedtls/ssl_ciphersuites.h"
#include "third_party/mbedtls/x509_crt.h"

#define TLS_META "cosmo.tls.engine"

struct LuaTls {
  mbedtls_ssl_context ssl;
  mbedtls_ssl_config conf;
  mbedtls_ctr_drbg_context drbg;
  int fd;
  char started;
  char handshaked;
  char closed;
  uint16_t *suites;
  mbedtls_ecp_group_id *curves;
  char **alpn;
};

static int TlsBioSend(void *ctx, const unsigned char *buf, size_t len) {
  ssize_t rc;
  struct LuaTls *t = ctx;
  rc = send(t->fd, buf, len, MSG_NOSIGNAL);
  if (rc < 0) {
    if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
      return MBEDTLS_ERR_SSL_WANT_WRITE;
    if (errno == EPIPE || errno == ECONNRESET)
      return MBEDTLS_ERR_NET_CONN_RESET;
    return MBEDTLS_ERR_NET_SEND_FAILED;
  }
  return rc;
}

static int TlsBioRecv(void *ctx, unsigned char *buf, size_t len) {
  ssize_t rc;
  struct LuaTls *t = ctx;
  rc = recv(t->fd, buf, len, 0);
  if (rc < 0) {
    if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
      return MBEDTLS_ERR_SSL_WANT_READ;
    if (errno == ECONNRESET)
      return MBEDTLS_ERR_NET_CONN_RESET;
    return MBEDTLS_ERR_NET_RECV_FAILED;
  }
  if (!rc && len)
    return MBEDTLS_ERR_NET_CONN_RESET; /* peer vanished without close_notify */
  return rc;
}

/* answers "want_read" or "want_write" for the two non-errors, and a
   human readable message for everything else */
static int TlsPushWant(lua_State *L, int rc) {
  char msg[128];
  if (rc == MBEDTLS_ERR_SSL_WANT_READ) {
    lua_pushnil(L);
    lua_pushliteral(L, "want read");
    lua_pushliteral(L, "want_read");
    return 3;
  }
  if (rc == MBEDTLS_ERR_SSL_WANT_WRITE) {
    lua_pushnil(L);
    lua_pushliteral(L, "want write");
    lua_pushliteral(L, "want_write");
    return 3;
  }
  mbedtls_strerror(rc, msg, sizeof(msg));
  lua_pushnil(L);
  lua_pushstring(L, msg);
  lua_pushinteger(L, rc);
  return 3;
}

/*  The engine lives in malloc'd memory with a pointer to it in the
    userdata, rather than inside the userdata itself.  mbedtls' contexts
    want stronger alignment than Lua gives a userdata body. */
static struct LuaTls *TlsCheck(lua_State *L) {
  struct LuaTls **ud = luaL_checkudata(L, 1, TLS_META);
  if (!*ud)
    luaL_error(L, "tls engine is closed");
  return *ud;
}

static int TlsHandshake(lua_State *L) {
  int rc;
  struct LuaTls *t = TlsCheck(L);
  if (t->handshaked) {
    lua_pushboolean(L, 1);
    return 1;
  }
  rc = mbedtls_ssl_handshake(&t->ssl);
  if (!rc) {
    t->handshaked = 1;
    lua_pushboolean(L, 1);
    return 1;
  }
  return TlsPushWant(L, rc);
}

static int TlsRead(lua_State *L) {
  int rc;
  char *buf;
  struct LuaTls *t = TlsCheck(L);
  lua_Integer n = luaL_optinteger(L, 2, 16384);
  if (n <= 0 || n > (1 << 20))
    n = 16384;
  if (t->closed) {
    lua_pushliteral(L, "");
    return 1;
  }
  buf = malloc(n);
  if (!buf)
    return luaL_error(L, "out of memory");
  rc = mbedtls_ssl_read(&t->ssl, (unsigned char *)buf, n);
  if (rc > 0) {
    lua_pushlstring(L, buf, rc);
    free(buf);
    return 1;
  }
  free(buf);
  if (!rc || rc == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) {
    t->closed = 1;
    lua_pushliteral(L, ""); /* end of stream, the way recv() spells it */
    return 1;
  }
  return TlsPushWant(L, rc);
}

static int TlsWrite(lua_State *L) {
  int rc;
  size_t len;
  const char *data;
  struct LuaTls *t = TlsCheck(L);
  data = luaL_checklstring(L, 2, &len);
  if (!len) {
    lua_pushinteger(L, 0);
    return 1;
  }
  rc = mbedtls_ssl_write(&t->ssl, (const unsigned char *)data, len);
  if (rc > 0) {
    lua_pushinteger(L, rc);
    return 1;
  }
  return TlsPushWant(L, rc);
}

static int TlsGetAlpn(lua_State *L) {
  const char *p;
  struct LuaTls *t = TlsCheck(L);
  p = mbedtls_ssl_get_alpn_protocol(&t->ssl);
  if (p) {
    lua_pushstring(L, p);
  } else {
    lua_pushnil(L);
  }
  return 1;
}

static int TlsGetVerifyResult(lua_State *L) {
  char msg[256];
  uint32_t flags;
  struct LuaTls *t = TlsCheck(L);
  flags = mbedtls_ssl_get_verify_result(&t->ssl);
  lua_pushinteger(L, flags);
  if (flags) {
    mbedtls_x509_crt_verify_info(msg, sizeof(msg), "", flags);
    lua_pushstring(L, msg);
  } else {
    lua_pushliteral(L, "ok");
  }
  return 2;
}

static int TlsGetCipher(lua_State *L) {
  struct LuaTls *t = TlsCheck(L);
  lua_pushstring(L, mbedtls_ssl_get_ciphersuite(&t->ssl));
  return 1;
}

static int TlsGetVersion(lua_State *L) {
  struct LuaTls *t = TlsCheck(L);
  lua_pushstring(L, mbedtls_ssl_get_version(&t->ssl));
  return 1;
}

static void TlsFree(struct LuaTls *t) {
  if (t->alpn) {
    size_t i;
    for (i = 0; t->alpn[i]; ++i)
      free(t->alpn[i]);
    free(t->alpn);
    t->alpn = 0;
  }
  free(t->suites);
  free(t->curves);
  t->suites = 0;
  t->curves = 0;
  if (t->started) {
    mbedtls_ssl_free(&t->ssl);
    mbedtls_ssl_config_free(&t->conf);
    mbedtls_ctr_drbg_free(&t->drbg);
    t->started = 0;
  }
}

static int TlsClose(lua_State *L) {
  struct LuaTls *t = TlsCheck(L);
  if (t->started && t->handshaked && !t->closed)
    mbedtls_ssl_close_notify(&t->ssl);
  t->closed = 1;
  return 0;
}

static int TlsGc(lua_State *L) {
  struct LuaTls **ud = luaL_checkudata(L, 1, TLS_META);
  if (*ud) {
    TlsFree(*ud);
    free(*ud);
    *ud = 0;
  }
  return 0;
}

static const luaL_Reg kTlsMethods[] = {
    {"handshake", TlsHandshake},                //
    {"read", TlsRead},                          //
    {"write", TlsWrite},                        //
    {"close", TlsClose},                        //
    {"getAlpnSelected", TlsGetAlpn},            //
    {"getVerifyResult", TlsGetVerifyResult},    //
    {"getCipherInfo", TlsGetCipher},            //
    {"getVersion", TlsGetVersion},              //
    {0},                                        //
};

/* curve names, as OpenSSL and as lua-http spell them */
static mbedtls_ecp_group_id TlsCurveId(const char *name) {
  if (!strcasecmp(name, "P-256") || !strcasecmp(name, "prime256v1") ||
      !strcasecmp(name, "secp256r1"))
    return MBEDTLS_ECP_DP_SECP256R1;
  if (!strcasecmp(name, "P-384") || !strcasecmp(name, "secp384r1"))
    return MBEDTLS_ECP_DP_SECP384R1;
  if (!strcasecmp(name, "P-521") || !strcasecmp(name, "secp521r1"))
    return MBEDTLS_ECP_DP_SECP521R1;
  if (!strcasecmp(name, "X25519") || !strcasecmp(name, "curve25519"))
    return MBEDTLS_ECP_DP_CURVE25519;
  return MBEDTLS_ECP_DP_NONE;
}

static size_t TlsTableLen(lua_State *L, int tbl, const char *field) {
  size_t n;
  lua_getfield(L, tbl, field);
  if (!lua_istable(L, -1)) {
    lua_pop(L, 1);
    return 0;
  }
  n = lua_rawlen(L, -1);
  lua_pop(L, 1);
  return n;
}

/* tls.engine{fd=,server=,hostname=,authmode=,ciphers={},curves={},
              alpn={},minver=,cert=,key=} */
static int TlsNew(lua_State *L) {
  int rc;
  size_t i, n;
  struct LuaTls *t;
  luaL_checktype(L, 1, LUA_TTABLE);
  struct LuaTls **ud = lua_newuserdatauv(L, sizeof(t), 1);
  *ud = 0;
  t = calloc(1, sizeof(*t));
  if (!t)
    return luaL_error(L, "out of memory");
  *ud = t;
  if (luaL_newmetatable(L, TLS_META)) {
    luaL_newlib(L, kTlsMethods);
    lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, TlsGc);
    lua_setfield(L, -2, "__gc");
  }
  lua_setmetatable(L, -2);

  lua_getfield(L, 1, "fd");
  t->fd = (int)luaL_checkinteger(L, -1);
  lua_pop(L, 1);

  mbedtls_ssl_init(&t->ssl);
  mbedtls_ssl_config_init(&t->conf);
  /* cosmopolitan's mbedtls is built with MBEDTLS_NO_PLATFORM_ENTROPY, so
     the entropy module has no source to draw on and seeding through it
     is not an option.  InitializeRng is what the rest of the tree uses
     and it seeds from getrandom. */
  InitializeRng(&t->drbg);
  t->started = 1;

  lua_getfield(L, 1, "server");
  int server = lua_toboolean(L, -1);
  lua_pop(L, 1);

  if ((rc = mbedtls_ssl_config_defaults(
           &t->conf, server ? MBEDTLS_SSL_IS_SERVER : MBEDTLS_SSL_IS_CLIENT,
           MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT))) {
    lua_pushnil(L);
    lua_pushfstring(L, "config_defaults: %d", rc);
    return 2;
  }

  mbedtls_ssl_conf_rng(&t->conf, mbedtls_ctr_drbg_random, &t->drbg);

  /* this mbedtls is TLS 1.2 only, so the floor is all that is settable */
  lua_getfield(L, 1, "tls12only");
  if (lua_toboolean(L, -1))
    mbedtls_ssl_conf_min_version(&t->conf, MBEDTLS_SSL_MAJOR_VERSION_3,
                                 MBEDTLS_SSL_MINOR_VERSION_3);
  lua_pop(L, 1);

  lua_getfield(L, 1, "authmode");
  mbedtls_ssl_conf_authmode(
      &t->conf, lua_isnil(L, -1) ? MBEDTLS_SSL_VERIFY_NONE
                                 : (int)lua_tointeger(L, -1));
  lua_pop(L, 1);

  lua_getfield(L, 1, "cadefaults");
  if (lua_toboolean(L, -1))
    mbedtls_ssl_conf_ca_chain(&t->conf, GetSslRoots(), 0);
  lua_pop(L, 1);

  if ((n = TlsTableLen(L, 1, "ciphers"))) {
    size_t k = 0;
    t->suites = calloc(n + 1, sizeof(*t->suites));
    lua_getfield(L, 1, "ciphers");
    for (i = 1; i <= n; ++i) {
      const mbedtls_ssl_ciphersuite_t *cs;
      lua_rawgeti(L, -1, i);
      cs = mbedtls_ssl_ciphersuite_from_string(lua_tostring(L, -1));
      if (cs)
        t->suites[k++] = cs->id;
      lua_pop(L, 1);
    }
    lua_pop(L, 1);
    if (k)
      mbedtls_ssl_conf_ciphersuites(&t->conf, t->suites);
  }

  if ((n = TlsTableLen(L, 1, "curves"))) {
    size_t k = 0;
    t->curves = calloc(n + 1, sizeof(*t->curves));
    lua_getfield(L, 1, "curves");
    for (i = 1; i <= n; ++i) {
      mbedtls_ecp_group_id id;
      lua_rawgeti(L, -1, i);
      id = TlsCurveId(lua_tostring(L, -1));
      /*  Drop curves this build does not have.  lua-http asks for
          P-521, which cosmopolitan's mbedtls leaves out, and a group id
          the library does not know makes the handshake fail with
          BAD_CONFIG rather than being ignored. */
      if (id != MBEDTLS_ECP_DP_NONE && mbedtls_ecp_curve_info_from_grp_id(id))
        t->curves[k++] = id;
      lua_pop(L, 1);
    }
    lua_pop(L, 1);
    t->curves[k] = MBEDTLS_ECP_DP_NONE;
    if (k)
      mbedtls_ssl_conf_curves(&t->conf, t->curves);
  }

  if ((n = TlsTableLen(L, 1, "alpn"))) {
    t->alpn = calloc(n + 1, sizeof(*t->alpn));
    lua_getfield(L, 1, "alpn");
    for (i = 1; i <= n; ++i) {
      lua_rawgeti(L, -1, i);
      t->alpn[i - 1] = strdup(lua_tostring(L, -1));
      lua_pop(L, 1);
    }
    lua_pop(L, 1);
    mbedtls_ssl_conf_alpn_protocols(&t->conf, (const char **)t->alpn);
  }

  if ((rc = mbedtls_ssl_setup(&t->ssl, &t->conf))) {
    lua_pushnil(L);
    lua_pushfstring(L, "ssl_setup: %d (suites=%d curves=%d alpn=%d)", rc,
                    (int)(t->suites ? 1 : 0), (int)(t->curves ? 1 : 0),
                    (int)(t->alpn ? 1 : 0));
    return 2;
  }

  lua_getfield(L, 1, "hostname");
  if (lua_isstring(L, -1))
    mbedtls_ssl_set_hostname(&t->ssl, lua_tostring(L, -1));
  lua_pop(L, 1);

  mbedtls_ssl_set_bio(&t->ssl, t, TlsBioSend, TlsBioRecv, 0);
  return 1;
}

void LuaTlsEngineInit(lua_State *L) {
  lua_pushcfunction(L, TlsNew);
  lua_setfield(L, -2, "engine");
  lua_pushinteger(L, MBEDTLS_SSL_VERIFY_NONE);
  lua_setfield(L, -2, "VERIFY_NONE");
  lua_pushinteger(L, MBEDTLS_SSL_VERIFY_OPTIONAL);
  lua_setfield(L, -2, "VERIFY_OPTIONAL");
  lua_pushinteger(L, MBEDTLS_SSL_VERIFY_REQUIRED);
  lua_setfield(L, -2, "VERIFY_REQUIRED");
}
