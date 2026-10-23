#ifndef COSMOPOLITAN_THIRD_PARTY_LUAPOSIX_LPOSIXPRELOAD_H_
#define COSMOPOLITAN_THIRD_PARTY_LUAPOSIX_LPOSIXPRELOAD_H_
#include "third_party/lua/lua.h"
COSMOPOLITAN_C_START_

int luaopen_posix_ctype(lua_State *);
int luaopen_posix_dirent(lua_State *);
int luaopen_posix_errno(lua_State *);
int luaopen_posix_fcntl(lua_State *);
int luaopen_posix_fnmatch(lua_State *);
int luaopen_posix_glob(lua_State *);
int luaopen_posix_grp(lua_State *);
int luaopen_posix_libgen(lua_State *);
int luaopen_posix_poll(lua_State *);
int luaopen_posix_pwd(lua_State *);
int luaopen_posix_sched(lua_State *);
int luaopen_posix_signal(lua_State *);
int luaopen_posix_stdio(lua_State *);
int luaopen_posix_stdlib(lua_State *);
int luaopen_posix_sys_msg(lua_State *);
int luaopen_posix_sys_resource(lua_State *);
int luaopen_posix_sys_socket(lua_State *);
int luaopen_posix_sys_stat(lua_State *);
int luaopen_posix_sys_statvfs(lua_State *);
int luaopen_posix_sys_time(lua_State *);
int luaopen_posix_sys_times(lua_State *);
int luaopen_posix_sys_utsname(lua_State *);
int luaopen_posix_sys_wait(lua_State *);
int luaopen_posix_syslog(lua_State *);
int luaopen_posix_termio(lua_State *);
int luaopen_posix_time(lua_State *);
int luaopen_posix_unistd(lua_State *);
int luaopen_posix_utime(lua_State *);

/* puts every posix.* C submodule in package.preload, so that
   `require "posix.unistd"` resolves without a filesystem lookup. */
void luaL_preloadposix(lua_State *);

COSMOPOLITAN_C_END_
#endif /* COSMOPOLITAN_THIRD_PARTY_LUAPOSIX_LPOSIXPRELOAD_H_ */
