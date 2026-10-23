#!/usr/bin/env python3
"""Vendor luaposix and LuaFileSystem into Cosmopolitan's Lua.

Usage:
  scripts/luaext.py vendor   download upstream, port it to cosmo libc, and
                             write third_party/luaposix + third_party/lfs
  scripts/luaext.py wire     make the monorepo build them (idempotent edits
                             to Makefile, third_party/lua/BUILD.mk and
                             third_party/lua/lua.main.c)
  scripts/luaext.py build    make x86_64 + aarch64, then apelink the two
                             into one fat APE at o/lua.com
  scripts/luaext.py test     run scripts/luaext_test.lua on o/lua.com
                             natively, on the aarch64 build under qemu,
                             and on o/lua.com under wine
  scripts/luaext.py all      vendor, wire, build, test

Cosmo's Lua has no dlopen-based module loading (loadlib.c's searcher is
there, but an APE is a static binary and there are no .so files to find),
so both libraries are compiled into lua.a's binary and registered in
package.preload.  `require` finds preloaded modules before it ever
touches the filesystem, so `require 'posix.unistd'` and `require 'lfs'`
work unchanged, and code that never requires them pays nothing but disk
space.  luaposix's pure-Lua half (posix/init.lua and friends) is stored
in the APE's zip directory under /zip/.lua/, which is already the first
entry of cosmo's LUA_PATH.
"""
import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DL = ROOT / "o" / "luaext"

LUAPOSIX_VERSION = "36.3"
LUAPOSIX_URL = ("https://github.com/luaposix/luaposix/archive/refs/tags/"
                "v%s.tar.gz" % LUAPOSIX_VERSION)
LUAPOSIX_SHA256 = "82cd9a96c41a4a3205c050206f0564ff4456f773a8f9ffc9235ff8f1907ca5e6"

LFS_VERSION = "1.8.0"
LFS_TAG = "v1_8_0"
LFS_URL = ("https://github.com/lunarmodules/luafilesystem/archive/refs/tags/"
           "%s.tar.gz" % LFS_TAG)
LFS_SHA256 = "16d17c788b8093f2047325343f5e9b74cccb1ea96001e45914a58bbae8932495"

POSIX_DIR = ROOT / "third_party/luaposix"
LFS_DIR = ROOT / "third_party/lfs"

# the 28 C submodules, in posix.c's include order.  the name on the left
# is the `require` name, the luaopen_ symbol is the same with dots turned
# into underscores, which is also how Lua's own preload searcher mangles
# submodule names.
MODULES = [
    "ctype", "dirent", "errno", "fcntl", "fnmatch", "glob", "grp", "libgen",
    "poll", "pwd", "sched", "signal", "stdio", "stdlib", "sys/msg",
    "sys/resource", "sys/socket", "sys/stat", "sys/statvfs", "sys/time",
    "sys/times", "sys/utsname", "sys/wait", "syslog", "termio", "time",
    "unistd", "utime",
]


COSMO_H = '''/*-*- mode:c;indent-tabs-mode:nil;c-basic-offset:2;tab-width:8;coding:utf-8 -*-│
│ vi: set et ft=c ts=2 sts=2 sw=2 fenc=utf-8                               :vi │
╚──────────────────────────────────────────────────────────────────────────────╝
│                                                                              │
│  Cosmopolitan configuration for luaposix.  Force-included (see BUILD.mk)     │
│  into every luaposix translation unit, because upstream reads its HAVE_*     │
│  feature macros before it includes anything of its own.                      │
│                                                                              │
╚─────────────────────────────────────────────────────────────────────────────*/
#ifndef COSMOPOLITAN_THIRD_PARTY_LUAPOSIX_COSMO_H_
#define COSMOPOLITAN_THIRD_PARTY_LUAPOSIX_COSMO_H_
/* this file is force-included ahead of everything, including the build's
   own -include libc/integral/normalize.inc, so it must not include any
   cosmopolitan header: it would be parsed before the compiler has been
   normalized, and mkdeps would reject the undeclared dependency.  macros
   only, therefore; the two shims below expand at their use sites, where
   <sys/stat.h> and <errno.h> have long since been included. */

/* upstream takes these from autoconf; it only uses them to build the
   `version` string each submodule exposes. */
#define PACKAGE "luaposix"
#define VERSION "%(version)s"

/* what cosmopolitan libc actually has.  everything not listed here is
   left undefined, which upstream reads as 0 and compiles out: the
   function is then simply absent from its module table, exactly as it
   would be on a Unix that lacks it. */
#define HAVE_CRYPT              1
#define HAVE_CRYPT_H            1
#define HAVE_DECL_FDATASYNC     1
#define HAVE_FDATASYNC          1
#define HAVE_NET_IF_H           1
#define HAVE_POSIX_FADVISE      1
#define HAVE_SCHED_H            1
#define HAVE_STATVFS            1
#define HAVE_TERMIOS_H          1
#define HAVE_TM_GMTOFF          1
#define HAVE_TM_ZONE            1
#define HAVE_WS_XPIXEL          1
#define HAVE_WS_YPIXEL          1

/* gethostid() is declared by libc/runtime/runtime.h but no cosmo libc
   implements it, so asking for it would break the link. */
#define HAVE_GETHOSTID          0
/* no SysV message queues, no sched_{get,set}scheduler, and no Linux-only
   netlink/packet socket families in cosmopolitan. */
#define HAVE_SYSV_MESSAGING     0
#define HAVE_SYS_MSG_H          0
#define HAVE_MSGRCV             0
#define HAVE_MSGSND             0
#define HAVE_SCHED_GETSCHEDULER 0
#define HAVE_SCHED_SETSCHEDULER 0
#define HAVE_LINUX_NETLINK_H    0
#define HAVE_LINUX_IF_PACKET_H  0

#ifndef _POSIX_PATH_MAX
#define _POSIX_PATH_MAX 256
#endif

/* upstream decides whether to bind mkdtemp() from _POSIX_C_SOURCE and
   _XOPEN_SOURCE, which cosmopolitan does not set, even though it sets
   _POSIX_VERSION to 200809L and has the function.  without this,
   posix.stdlib.mkdtemp is a stub that reports "not implemented by host
   C library". */
#define LPOSIX_2008_COMPLIANT 1

/* likewise for clock_getres() and clock_gettime(), which upstream gates
   on _POSIX_TIMERS.  cosmopolitan has both, and advertises the related
   _POSIX_MONOTONIC_CLOCK and _POSIX_CPUTIME, but never defines this
   one. */
#define _POSIX_TIMERS 200809L

/* cosmopolitan has no mkfifo().  route it through mknod(), which is the
   usual definition, and which also means posix.sys.stat.mkfifo starts
   working by itself if cosmo ever grows named pipes.  today it does not,
   and mknod() answers S_IFIFO with ENOSYS on every host, on purpose
   (see libc/calls/mknod.c). */
#define mkfifo(PATH, MODE) mknod(PATH, ((MODE) & ~S_IFMT) | S_IFIFO, 0)

/* cosmopolitan has no if_nametoindex().  keep posix.sys.socket's binding
   present (so copied code still loads) but fail it cleanly. */
#define if_nametoindex(IFNAME) ((void)(IFNAME), errno = ENOSYS, 0u)

#endif /* COSMOPOLITAN_THIRD_PARTY_LUAPOSIX_COSMO_H_ */
'''


def lposixpreload_h():
    decls = "\n".join(
        "int luaopen_posix_%s(lua_State *);" % m.replace("/", "_")
        for m in MODULES)
    return '''#ifndef COSMOPOLITAN_THIRD_PARTY_LUAPOSIX_LPOSIXPRELOAD_H_
#define COSMOPOLITAN_THIRD_PARTY_LUAPOSIX_LPOSIXPRELOAD_H_
#include "third_party/lua/lua.h"
COSMOPOLITAN_C_START_

%s

/* puts every posix.* C submodule in package.preload, so that
   `require "posix.unistd"` resolves without a filesystem lookup. */
void luaL_preloadposix(lua_State *);

COSMOPOLITAN_C_END_
#endif /* COSMOPOLITAN_THIRD_PARTY_LUAPOSIX_LPOSIXPRELOAD_H_ */
''' % decls


def lposixpreload_c():
    rows = "\n".join(
        '    {"posix.%s", luaopen_posix_%s},' % (m.replace("/", "."),
                                                 m.replace("/", "_"))
        for m in MODULES)
    return '''/*-*- mode:c;indent-tabs-mode:nil;c-basic-offset:2;tab-width:8;coding:utf-8 -*-│
│ vi: set et ft=c ts=2 sts=2 sw=2 fenc=utf-8                               :vi │
╚──────────────────────────────────────────────────────────────────────────────╝
│                                                                              │
│  Preload registration for luaposix.  Generated by scripts/luaext.py.         │
│                                                                              │
╚─────────────────────────────────────────────────────────────────────────────*/
#include "third_party/luaposix/lposixpreload.h"
#include "third_party/lua/lauxlib.h"
#include "third_party/lua/lua.h"

__static_yoink("luaposix_notice");
/* the pure-Lua half of luaposix lives in this binary's zip store, under
   /zip/.lua/posix/, which is the first entry of cosmo's LUA_PATH. */
__static_yoink("zipos");

static const luaL_Reg kLuaPosixModules[] = {
%s
};

void luaL_preloadposix(lua_State *L) {
  int i;
  luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
  for (i = 0; i < (int)(sizeof(kLuaPosixModules) / sizeof(*kLuaPosixModules));
       ++i) {
    lua_pushcfunction(L, kLuaPosixModules[i].func);
    lua_setfield(L, -2, kLuaPosixModules[i].name);
  }
  lua_pop(L, 1); /* remove PRELOAD table */
}
''' % rows


NOTICE_C = '''__notice(luaposix_notice, "\\
luaposix %(version)s (MIT License)\\n\\
Copyright 2006-2025 luaposix authors.");
'''

LFS_PRELOAD_C = '''/*-*- mode:c;indent-tabs-mode:nil;c-basic-offset:2;tab-width:8;coding:utf-8 -*-│
│ vi: set et ft=c ts=2 sts=2 sw=2 fenc=utf-8                               :vi │
╚──────────────────────────────────────────────────────────────────────────────╝
│                                                                              │
│  Preload registration for LuaFileSystem.  Generated by scripts/luaext.py.    │
│                                                                              │
╚─────────────────────────────────────────────────────────────────────────────*/
#include "third_party/lfs/lfspreload.h"
#include "third_party/lfs/lfs.h"
#include "third_party/lua/lauxlib.h"
#include "third_party/lua/lua.h"

__static_yoink("lfs_notice");

void luaL_preloadlfs(lua_State *L) {
  luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
  lua_pushcfunction(L, luaopen_lfs);
  lua_setfield(L, -2, "lfs");
  lua_pop(L, 1); /* remove PRELOAD table */
}
'''

LFS_PRELOAD_H = '''#ifndef COSMOPOLITAN_THIRD_PARTY_LFS_LFSPRELOAD_H_
#define COSMOPOLITAN_THIRD_PARTY_LFS_LFSPRELOAD_H_
#include "third_party/lua/lua.h"
COSMOPOLITAN_C_START_

/* puts LuaFileSystem in package.preload, so that `require "lfs"`
   resolves without a filesystem lookup. */
void luaL_preloadlfs(lua_State *);

COSMOPOLITAN_C_END_
#endif /* COSMOPOLITAN_THIRD_PARTY_LFS_LFSPRELOAD_H_ */
'''

LFS_NOTICE_C = '''__notice(lfs_notice, "\\
LuaFileSystem %(version)s (MIT License)\\n\\
Copyright 2003-2020 Kepler Project.");
'''


MK_HEADER = ("#-*-mode:makefile-gmake;indent-tabs-mode:t;tab-width:8;"
             "coding:utf-8-*-┐\n"
             "#── vi: set noet ft=make ts=8 sw=8 fenc=utf-8 :vi "
             "──────────"
             "─────────┘\n"
             "#\n"
             "# generated by scripts/luaext.py -- edit that, not this\n")

COMMON_DIRECTDEPS = [
    "LIBC_CALLS", "LIBC_FMT", "LIBC_INTRIN", "LIBC_MEM", "LIBC_NEXGEN32E",
    "LIBC_PROC", "LIBC_RUNTIME", "LIBC_STDIO", "LIBC_STR", "LIBC_SYSV",
    "LIBC_SYSV_CALLS", "LIBC_X",
]
LUA_PKG = "o/$(MODE)/third_party/lua/lua.a.pkg"

POSIX_DIRECTDEPS = COMMON_DIRECTDEPS + [
    "LIBC_SOCK", "LIBC_LOG", "LIBC_THREAD", "THIRD_PARTY_GETOPT",
    "THIRD_PARTY_MUSL", "THIRD_PARTY_TZ",
]


def mkvar(name, vals):
    """NAME =\\\\\\n\\tVAL \\\\\\n\\tVAL\\n"""
    return "%s =\\\n%s\n" % (name, " \\\n".join("\t" + v for v in sorted(vals)))


def build_mk(up, path, aname, srcs, hdrs, incs, directdeps, extra="",
             ok_hdrs=()):
    t = [MK_HEADER, "\nPKGS += %s\n\n" % up]
    t.append("%s_ARTIFACTS += %s_A\n" % (up, up))
    t.append("%s = $(%s_A_DEPS) $(%s_A)\n" % (up, up, up))
    t.append("%s_A = o/$(MODE)/%s/%s.a\n\n" % (up, path, aname))
    t.append(mkvar("%s_A_HDRS" % up, hdrs) + "\n")
    t.append(mkvar("%s_A_SRCS" % up, srcs) + "\n")
    if incs:
        t.append(mkvar("%s_A_INCS" % up, incs) + "\n")
    t.append("%s_A_OBJS = $(%s_A_SRCS:%%.c=o/$(MODE)/%%.o)\n\n" % (up, up))
    # only the headers written for cosmo get the strict standalone-header
    # check; upstream's lfs.h names lua_State without including lua.h.
    if ok_hdrs:
        t.append(mkvar("%s_A_OK_HDRS" % up, ok_hdrs) + "\n")
        t.append("%s_A_CHECKS =\\\n\t$(%s_A).pkg \\\n"
                 "\t$(%s_A_OK_HDRS:%%=o/$(MODE)/%%.ok)\n\n" % (up, up, up))
    else:
        t.append("%s_A_CHECKS = $(%s_A).pkg\n\n" % (up, up))
    t.append(mkvar("%s_A_DIRECTDEPS" % up, directdeps) + "\n")
    t.append("%s_A_DEPS :=\\\n\t$(call uniq,$(foreach x,"
             "$(%s_A_DIRECTDEPS),$($(x))))\n\n" % (up, up))
    t.append("$(%s_A):\\\n\t%s/ \\\n\t$(%s_A).pkg \\\n\t$(%s_A_OBJS)\n\n"
             % (up, path, up, up))
    t.append("$(%s_A).pkg:\\\n\t$(%s_A_OBJS) \\\n\t%s \\\n\t$(foreach x,"
             "$(%s_A_DIRECTDEPS),$($(x)_A).pkg)\n\n" % (up, up, LUA_PKG, up))
    t.append(extra)
    t.append("%s_LIBS = $(foreach x,$(%s_ARTIFACTS),$($(x)))\n" % (up, up))
    t.append("%s_SRCS = $(foreach x,$(%s_ARTIFACTS),$($(x)_SRCS))\n" % (up, up))
    t.append("%s_HDRS = $(foreach x,$(%s_ARTIFACTS),$($(x)_HDRS))\n" % (up, up))
    t.append("%s_INCS = $(foreach x,$(%s_ARTIFACTS),$($(x)_INCS))\n" % (up, up))
    t.append("%s_OBJS = $(foreach x,$(%s_ARTIFACTS),$($(x)_OBJS))\n" % (up, up))
    t.append("%s_CHECKS = $(foreach x,$(%s_ARTIFACTS),$($(x)_CHECKS))\n"
             % (up, up))
    t.append("$(%s_OBJS): %s/BUILD.mk\n\n" % (up, path))
    t.append(".PHONY: o/$(MODE)/%s\n" % path)
    t.append("o/$(MODE)/%s: $(%s_CHECKS)\n" % (path, up))
    return "".join(t)


POSIX_EXTRA = """# upstream reads its HAVE_* feature macros before including anything of
# its own, so the cosmo configuration has to come in ahead of the source.
$(THIRD_PARTY_LUAPOSIX_A_OBJS): private CPPFLAGS +=\\
\t-include third_party/luaposix/cosmo.h

$(THIRD_PARTY_LUAPOSIX_A_OBJS): private CFLAGS +=\\
\t-ffunction-sections \\
\t-fdata-sections \\
\t-Wno-unused-variable \\
\t-Wno-address

# the pure-Lua half of luaposix, stored in the binary's zip directory as
# .lua/posix/*.lua, which is where cosmo's LUA_PATH looks first.  -C2
# strips the leading third_party/luaposix/ from each zip entry name.
THIRD_PARTY_LUAPOSIX_LUAS = $(wildcard third_party/luaposix/.lua/posix/*.lua)
THIRD_PARTY_LUAPOSIX_ZIPOBJS =\\
\t$(THIRD_PARTY_LUAPOSIX_LUAS:%=o/$(MODE)/%.zip.o)

$(THIRD_PARTY_LUAPOSIX_ZIPOBJS): private ZIPOBJ_FLAGS +=\\
\t-C2

"""

LFS_EXTRA = """$(THIRD_PARTY_LFS_A_OBJS): private CFLAGS +=\\
\t-ffunction-sections \\
\t-fdata-sections

"""


# ---------------------------------------------------------------- vendor

def fetch(url, sha256, name):
    DL.mkdir(parents=True, exist_ok=True)
    tgz = DL / name
    if not tgz.exists():
        print("==> downloading %s" % url)
        with urllib.request.urlopen(url) as r, open(tgz, "wb") as f:
            shutil.copyfileobj(r, f)
    got = hashlib.sha256(tgz.read_bytes()).hexdigest()
    if got != sha256:
        tgz.unlink()
        sys.exit("error: %s sha256 %s, expected %s" % (name, got, sha256))
    out = DL / name.replace(".tar.gz", "")
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    with tarfile.open(tgz) as t:
        t.extractall(out)
    (root,) = list(out.iterdir())
    return root


def rewrite(text, pairs):
    for old, new in pairs:
        if old not in text:
            sys.exit("error: expected to find %r to rewrite" % old)
        text = text.replace(old, new)
    return text


def patch(path, edits):
    """edits is [(old, new, count)]; every one must match exactly count
    times, so that a new upstream release fails loudly here instead of
    silently dropping a fix."""
    s = path.read_text()
    for old, new, count in edits:
        got = s.count(old)
        if got != count:
            sys.exit("error: %s: expected %d match(es) of %r, found %d"
                     % (path, count, old[:70], got))
        s = s.replace(old, new)
    path.write_text(s)


# Cosmopolitan resolves anything whose value differs between the host
# platforms a single APE runs on (AF_INET6, SOL_SOCKET, POLLIN, F_SETLK,
# ...) at link time rather than compile time.  That makes those constants
# unusable as `case` labels and in static initializers.  These edits move
# the dispatch onto locally computed compile-time codes without changing
# any behavior.  See third_party/luaposix/README.cosmo.
POSIX_EDITS = {
    "fcntl.c": [("""	switch (cmd)
	{
		case F_SETLK:
		case F_SETLKW:
		case F_GETLK:
""", """	/* cosmo: F_* are link-time constants, so switch on a local code */
	switch (cmd == F_SETLK || cmd == F_SETLKW || cmd == F_GETLK)
	{
		case 1:
""", 1)],
    "poll.c": [("""} poll_event_map[] = {
#define MAP(_NAME) \\
	{POLL##_NAME, #_NAME}
	MAP(IN),
	MAP(PRI),
	MAP(OUT),
	MAP(ERR),
	MAP(HUP),
	MAP(NVAL),
#undef MAP
};
""", """} poll_event_map[] = {
#define MAP(_NAME) \\
	{0, #_NAME}
	MAP(IN),
	MAP(PRI),
	MAP(OUT),
	MAP(ERR),
	MAP(HUP),
	MAP(NVAL),
#undef MAP
};

/* cosmo: POLL* are link-time constants, so they can't initialize the
   table above; fill in the bits when the module is opened instead. */
static void
poll_event_map_init(void)
{
	int i = 0;
#define MAP(_NAME) poll_event_map[i++].bit = POLL##_NAME
	MAP(IN);
	MAP(PRI);
	MAP(OUT);
	MAP(ERR);
	MAP(HUP);
	MAP(NVAL);
#undef MAP
}
""", 1),
                ("""luaopen_posix_poll(lua_State *L)
{
	luaL_newlib(L, posix_poll_fns);""",
                 """luaopen_posix_poll(lua_State *L)
{
	poll_event_map_init();
	luaL_newlib(L, posix_poll_fns);""", 1)],
    "unistd.c": [],
    "sys/socket.c": [],
}


SOCKET_CODES = '''#include <sys/un.h>

/* cosmo: AF_*, SOL_*, SO_*, IPPROTO_* and IPV6_* are link-time constants
   here, because their values differ between the platforms one APE binary
   has to run on.  That makes them unusable as switch case labels, so map
   them onto compile-time codes and leave the dispatch below alone. */

enum {
	LPOSIX_AF_OTHER = 0,
	LPOSIX_AF_INET,
	LPOSIX_AF_INET6,
	LPOSIX_AF_UNIX,
	LPOSIX_AF_NETLINK,
	LPOSIX_AF_PACKET
};

static int
lposix_afcode(int family)
{
	if (family == AF_INET)
		return LPOSIX_AF_INET;
	if (family == AF_INET6)
		return LPOSIX_AF_INET6;
	if (family == AF_UNIX)
		return LPOSIX_AF_UNIX;
#if HAVE_LINUX_NETLINK_H
	if (family == AF_NETLINK)
		return LPOSIX_AF_NETLINK;
#endif
#if HAVE_LINUX_IF_PACKET_H
	if (family == AF_PACKET)
		return LPOSIX_AF_PACKET;
#endif
	return LPOSIX_AF_OTHER;
}

enum {
	LPOSIX_LEVEL_OTHER = 0,
	LPOSIX_SOL_SOCKET,
	LPOSIX_IPPROTO_IPV6,
	LPOSIX_IPPROTO_TCP
};

static int
lposix_levelcode(int level)
{
	if (level == SOL_SOCKET)
		return LPOSIX_SOL_SOCKET;
#if defined IPV6_JOIN_GROUP && defined IPV6_LEAVE_GROUP
	if (level == IPPROTO_IPV6)
		return LPOSIX_IPPROTO_IPV6;
#endif
	if (level == IPPROTO_TCP)
		return LPOSIX_IPPROTO_TCP;
	return LPOSIX_LEVEL_OTHER;
}

enum {
	LPOSIX_SOCKOPT_OTHER = 0,
	LPOSIX_SO_LINGER,
	LPOSIX_SO_RCVTIMEO,
	LPOSIX_SO_SNDTIMEO,
	LPOSIX_SO_BINDTODEVICE
};

static int
lposix_sockoptcode(int optname)
{
	if (optname == SO_LINGER)
		return LPOSIX_SO_LINGER;
	if (optname == SO_RCVTIMEO)
		return LPOSIX_SO_RCVTIMEO;
	if (optname == SO_SNDTIMEO)
		return LPOSIX_SO_SNDTIMEO;
#ifdef SO_BINDTODEVICE
	if (optname == SO_BINDTODEVICE)
		return LPOSIX_SO_BINDTODEVICE;
#endif
	return LPOSIX_SOCKOPT_OTHER;
}

#if defined IPV6_JOIN_GROUP && defined IPV6_LEAVE_GROUP
enum {
	LPOSIX_IPV6OPT_OTHER = 0,
	LPOSIX_IPV6_JOIN_GROUP,
	LPOSIX_IPV6_LEAVE_GROUP
};

static int
lposix_ipv6optcode(int optname)
{
	if (optname == IPV6_JOIN_GROUP)
		return LPOSIX_IPV6_JOIN_GROUP;
	if (optname == IPV6_LEAVE_GROUP)
		return LPOSIX_IPV6_LEAVE_GROUP;
	return LPOSIX_IPV6OPT_OTHER;
}
#endif
'''

POSIX_EDITS["sys/socket.c"] = [
    ("#include <sys/un.h>\n", SOCKET_CODES, 1),
    ("\tswitch (family)\n", "\tswitch (lposix_afcode(family))\n", 2),
    ("\t\tcase AF_INET:\n", "\t\tcase LPOSIX_AF_INET:\n", 2),
    ("\t\tcase AF_INET6:\n", "\t\tcase LPOSIX_AF_INET6:\n", 2),
    ("\t\tcase AF_UNIX:\n", "\t\tcase LPOSIX_AF_UNIX:\n", 2),
    ("\t\tcase AF_NETLINK:\n", "\t\tcase LPOSIX_AF_NETLINK:\n", 2),
    ("\t\tcase AF_PACKET:\n", "\t\tcase LPOSIX_AF_PACKET:\n", 2),
    ("\tswitch (level)\n", "\tswitch (lposix_levelcode(level))\n", 2),
    ("\t\tcase SOL_SOCKET:\n\t\t\tswitch (optname)\n",
     "\t\tcase LPOSIX_SOL_SOCKET:\n\t\t\tswitch (lposix_sockoptcode(optname))\n",
     2),
    ("\t\tcase IPPROTO_IPV6:\n\t\t\tswitch (optname)\n",
     "\t\tcase LPOSIX_IPPROTO_IPV6:\n\t\t\tswitch (lposix_ipv6optcode(optname))\n",
     1),
    ("\t\tcase IPPROTO_TCP:\n\t\t\tswitch (optname)\n",
     "\t\tcase LPOSIX_IPPROTO_TCP:\n\t\t\tswitch (optname)\n", 1),
    ("\t\t\t\tcase SO_LINGER:\n", "\t\t\t\tcase LPOSIX_SO_LINGER:\n", 2),
    ("\t\t\t\tcase SO_RCVTIMEO:\n\t\t\t\tcase SO_SNDTIMEO:\n",
     "\t\t\t\tcase LPOSIX_SO_RCVTIMEO:\n\t\t\t\tcase LPOSIX_SO_SNDTIMEO:\n", 2),
    ("\t\t\t\tcase SO_BINDTODEVICE:\n",
     "\t\t\t\tcase LPOSIX_SO_BINDTODEVICE:\n", 2),
    ("\t\t\t\tcase IPV6_JOIN_GROUP:\n\t\t\t\tcase IPV6_LEAVE_GROUP:\n",
     "\t\t\t\tcase LPOSIX_IPV6_JOIN_GROUP:\n\t\t\t\tcase LPOSIX_IPV6_LEAVE_GROUP:\n",
     1),
]


GLOBAL_INCLUDE_REWRITES = [
    ('#include "_helpers.c"', '#include "third_party/luaposix/_helpers.c"'),
    ('#include "compat-5.2.c"', '#include "third_party/luaposix/compat-5.2.c"'),
    ('#include "compat-5.2.h"', '#include "third_party/luaposix/compat-5.2.h"'),
    ('#include "lua.h"', '#include "third_party/lua/lua.h"'),
    ('#include "lualib.h"', '#include "third_party/lua/lualib.h"'),
    ('#include "lauxlib.h"', '#include "third_party/lua/lauxlib.h"'),
    ('#include <lua.h>', '#include "third_party/lua/lua.h"'),
    ('#include <lualib.h>', '#include "third_party/lua/lualib.h"'),
    ('#include <lauxlib.h>', '#include "third_party/lua/lauxlib.h"'),
]

POSIX_README = '''DESCRIPTION

  luaposix is a POSIX binding for Lua: fork/exec, stat, dirent, fcntl,
  termios, sockets, signals, glob, and so forth, split into one module
  per POSIX header (posix.unistd, posix.sys.stat, ...).

PROVENANCE

  %(url)s
  luaposix %(version)s
  sha256 %(sha256)s

  Imported by scripts/luaext.py, which performs every modification
  listed below.  Re-run `scripts/luaext.py vendor` to reproduce this
  directory from upstream; it fails loudly if upstream has moved any of
  the code it patches.

LOCAL MODIFICATIONS

  Quoted includes were rewritten to cosmopolitan's repository-root form,
  e.g. `#include "lua.h"` became `#include "third_party/lua/lua.h"`, so
  that the monorepo's -nostdinc -iquote. build and its header dependency
  scanner both resolve them.  Upstream's unity build is kept: posix.c is
  the only translation unit, and it #includes the other twenty-eight.

  cosmo.h was added, and is force-included ahead of every translation
  unit (see BUILD.mk).  It supplies PACKAGE/VERSION, the HAVE_* feature
  macros that upstream normally gets from autoconf, a mkfifo() wrapper
  around mknod() and an ENOSYS if_nametoindex(), neither of which
  cosmopolitan libc has.  HAVE_GETHOSTID is 0 because cosmopolitan
  declares gethostid() without implementing it.

  fcntl.c, poll.c and sys/socket.c had `switch` statements rewritten to
  dispatch on locally computed codes.  Cosmopolitan resolves constants
  whose value differs across the platforms one APE binary runs on
  (F_SETLK, POLLIN, AF_INET6, SOL_SOCKET, SO_LINGER, IPV6_JOIN_GROUP,
  ...) at link time, so they cannot appear as case labels or in static
  initializers.  The control flow is otherwise untouched.

  lposixpreload.c was added.  It registers every C submodule in
  package.preload under its dotted name, because an APE is statically
  linked and there is no .so for Lua's C loader to dlopen.

  lib/posix/*.lua became .lua/posix/*.lua, which BUILD.mk stores in the
  binary's zip directory; /zip/.lua/?.lua is the first entry of cosmo's
  LUA_PATH.  version.lua was generated from upstream's version.lua.in.

  The parts of upstream that only matter to its own build (configure.ac,
  Makefile.am, slingshot, specs, docs) were not imported.
'''

LFS_README = '''DESCRIPTION

  LuaFileSystem exposes directory iteration, stat/lstat, symlinks, file
  locking, and mkdir/rmdir/chdir to Lua as the `lfs` module.

PROVENANCE

  %(url)s
  LuaFileSystem %(version)s
  sha256 %(sha256)s

  Imported by scripts/luaext.py.

LOCAL MODIFICATIONS

  Includes were rewritten to cosmopolitan's repository-root form, e.g.
  `#include <lua.h>` became `#include "third_party/lua/lua.h"`.

  lfspreload.c was added, which registers luaopen_lfs in
  package.preload so that `require "lfs"` works in a static binary.

  lfs.c itself is otherwise unmodified: it compiled against
  cosmopolitan libc for both x86_64 and aarch64 without a single
  warning on the first try.
'''


def vendor_luaposix():
    src = fetch(LUAPOSIX_URL, LUAPOSIX_SHA256, "luaposix.tar.gz")
    if POSIX_DIR.exists():
        shutil.rmtree(POSIX_DIR)
    (POSIX_DIR / "sys").mkdir(parents=True)
    (POSIX_DIR / ".lua" / "posix").mkdir(parents=True)
    for m in MODULES + ["posix"]:
        shutil.copy(src / "ext/posix" / (m + ".c"), POSIX_DIR / (m + ".c"))
    for f in ("_helpers.c", "compat-5.2.c", "compat-5.2.h"):
        shutil.copy(src / "ext/include" / f, POSIX_DIR / f)
    shutil.copy(src / "LICENSE", POSIX_DIR / "LICENSE")
    for rel, edits in POSIX_EDITS.items():
        if edits:
            patch(POSIX_DIR / rel, edits)
    for p in sorted(POSIX_DIR.rglob("*.[ch]")):
        s = p.read_text()
        for old, new in GLOBAL_INCLUDE_REWRITES:
            s = s.replace(old, new)
        p.write_text(s)
    posix_c = POSIX_DIR / "posix.c"
    s = posix_c.read_text()
    for m in MODULES:
        s = rewrite(s, [('#include "%s.c"' % m,
                         '#include "third_party/luaposix/%s.c"' % m)])
    posix_c.write_text(s)
    for p in sorted((src / "lib/posix").glob("*.lua")):
        shutil.copy(p, POSIX_DIR / ".lua/posix" / p.name)
    version_lua = (src / "lib/posix/version.lua.in").read_text()
    version_lua = version_lua.replace("@package@", "luaposix")
    version_lua = version_lua.replace("@version@", LUAPOSIX_VERSION)
    (POSIX_DIR / ".lua/posix/version.lua").write_text(version_lua)
    (POSIX_DIR / "cosmo.h").write_text(COSMO_H % {"version": LUAPOSIX_VERSION})
    (POSIX_DIR / "lposixpreload.h").write_text(lposixpreload_h())
    (POSIX_DIR / "lposixpreload.c").write_text(lposixpreload_c())
    (POSIX_DIR / "notice.c").write_text(
        NOTICE_C % {"version": LUAPOSIX_VERSION})
    (POSIX_DIR / "README.cosmo").write_text(POSIX_README % {
        "url": LUAPOSIX_URL, "version": LUAPOSIX_VERSION,
        "sha256": LUAPOSIX_SHA256})
    srcs = ["third_party/luaposix/" + f
            for f in ("posix.c", "lposixpreload.c", "notice.c")]
    incs = ["third_party/luaposix/" + m + ".c" for m in MODULES]
    incs += ["third_party/luaposix/_helpers.c",
             "third_party/luaposix/compat-5.2.c"]
    hdrs = ["third_party/luaposix/cosmo.h",
            "third_party/luaposix/lposixpreload.h",
            "third_party/luaposix/compat-5.2.h"]
    (POSIX_DIR / "BUILD.mk").write_text(build_mk(
        "THIRD_PARTY_LUAPOSIX", "third_party/luaposix", "luaposix",
        srcs, hdrs, incs, POSIX_DIRECTDEPS, POSIX_EXTRA,
        ok_hdrs=["third_party/luaposix/cosmo.h",
                 "third_party/luaposix/lposixpreload.h"]))
    print("==> vendored luaposix %s into %s" % (LUAPOSIX_VERSION, POSIX_DIR))


def vendor_lfs():
    src = fetch(LFS_URL, LFS_SHA256, "lfs.tar.gz")
    if LFS_DIR.exists():
        shutil.rmtree(LFS_DIR)
    LFS_DIR.mkdir(parents=True)
    for f in ("lfs.c", "lfs.h"):
        shutil.copy(src / "src" / f, LFS_DIR / f)
    shutil.copy(src / "LICENSE", LFS_DIR / "LICENSE")
    for p in sorted(LFS_DIR.glob("*.[ch]")):
        s = p.read_text()
        for old, new in GLOBAL_INCLUDE_REWRITES:
            s = s.replace(old, new)
        p.write_text(s)
    patch(LFS_DIR / "lfs.c", [('#include "lfs.h"',
                               '#include "third_party/lfs/lfs.h"', 1)])
    (LFS_DIR / "lfspreload.h").write_text(LFS_PRELOAD_H)
    (LFS_DIR / "lfspreload.c").write_text(LFS_PRELOAD_C)
    (LFS_DIR / "notice.c").write_text(LFS_NOTICE_C % {"version": LFS_VERSION})
    (LFS_DIR / "README.cosmo").write_text(LFS_README % {
        "url": LFS_URL, "version": LFS_VERSION, "sha256": LFS_SHA256})
    srcs = ["third_party/lfs/" + f
            for f in ("lfs.c", "lfspreload.c", "notice.c")]
    hdrs = ["third_party/lfs/lfs.h", "third_party/lfs/lfspreload.h"]
    (LFS_DIR / "BUILD.mk").write_text(build_mk(
        "THIRD_PARTY_LFS", "third_party/lfs", "lfs", srcs, hdrs, [],
        COMMON_DIRECTDEPS, LFS_EXTRA,
        ok_hdrs=["third_party/lfs/lfspreload.h"]))
    print("==> vendored LuaFileSystem %s into %s" % (LFS_VERSION, LFS_DIR))


# ------------------------------------------------------------------ wire

MAKEFILE_ANCHOR = "include third_party/lua/BUILD.mk"
MAKEFILE_INSERT = ("include third_party/lfs/BUILD.mk\n"
                   "include third_party/luaposix/BUILD.mk\n")

# appended at the end on purpose: LINKARGS reverses the prerequisite
# order, so the last package listed here is the first archive on the link
# line, which is where luaposix.a and lfs.a have to be relative to the
# lua.a they take their lua_* symbols from.
LUA_BUILD_MK_OLD = """	THIRD_PARTY_LUA_UNIX					\\
	TOOL_ARGS
"""
LUA_BUILD_MK_NEW = """	THIRD_PARTY_LUA_UNIX					\\
	TOOL_ARGS						\\
	THIRD_PARTY_LFS						\\
	THIRD_PARTY_LUAPOSIX
"""

LUA_DBG_OLD = """o/$(MODE)/third_party/lua/lua.dbg:				\\
		$(THIRD_PARTY_LUA_LUA_DEPS)			\\
		o/$(MODE)/third_party/lua/lua.pkg		\\"""
LUA_DBG_NEW = """o/$(MODE)/third_party/lua/lua.dbg:				\\
		$(THIRD_PARTY_LUA_LUA_DEPS)			\\
		$(THIRD_PARTY_LUAPOSIX_ZIPOBJS)			\\
		o/$(MODE)/third_party/lua/lua.pkg		\\"""

MAIN_OLD = """  luaL_requiref(L, "unix", LuaUnix, 1);
  lua_pop(L, 1);"""
MAIN_NEW = """  luaL_requiref(L, "unix", LuaUnix, 1);
  lua_pop(L, 1);
  /* these are in package.preload rather than loaded here, so that
     `require "posix.unistd"` and `require "lfs"` work in copied code
     without every script paying for thirty module tables it never
     touches. */
  luaL_preloadposix(L);
  luaL_preloadlfs(L);"""

MAIN_INCLUDE_OLD = '#include "third_party/lua/lunix.h"'
MAIN_INCLUDE_NEW = ('#include "third_party/lua/lunix.h"\n'
                    '#include "third_party/lfs/lfspreload.h"\n'
                    '#include "third_party/luaposix/lposixpreload.h"')


def wire_one(path, old, new, marker):
    s = path.read_text()
    if marker in s:
        print("    %s already wired" % path.relative_to(ROOT))
        return
    if s.count(old) != 1:
        sys.exit("error: %s: expected exactly one %r" % (path, old[:60]))
    path.write_text(s.replace(old, new))
    print("    wired %s" % path.relative_to(ROOT))


def wire():
    print("==> wiring the monorepo build")
    wire_one(ROOT / "Makefile", MAKEFILE_ANCHOR,
             MAKEFILE_INSERT + MAKEFILE_ANCHOR,
             "include third_party/luaposix/BUILD.mk")
    mk = ROOT / "third_party/lua/BUILD.mk"
    wire_one(mk, LUA_BUILD_MK_OLD, LUA_BUILD_MK_NEW, "THIRD_PARTY_LUAPOSIX")
    wire_one(mk, LUA_DBG_OLD, LUA_DBG_NEW, "THIRD_PARTY_LUAPOSIX_ZIPOBJS")
    main = ROOT / "third_party/lua/lua.main.c"
    wire_one(main, MAIN_INCLUDE_OLD, MAIN_INCLUDE_NEW, "lposixpreload.h")
    wire_one(main, MAIN_OLD, MAIN_NEW, "luaL_preloadposix")


# ----------------------------------------------------------------- build

def run(argv, **kw):
    """runs through bash on purpose: these are APE binaries, and python's
    subprocess has no ENOEXEC fallback for the shell header they open
    with, while bash does."""
    cmd = " ".join("'%s'" % a for a in argv)
    print("+ " + cmd)
    subprocess.run(["bash", "-c", cmd], check=True, cwd=ROOT, **kw)


def build():
    j = "-j%d" % (os.cpu_count() or 4)
    # the .dbg files are the per-arch ELF executables apelink fattens;
    # the extensionless ones are the per-arch APEs, built here too so
    # that the aarch64 one can be tested on its own under qemu.
    run(["make", "MODE=x86_64", j,
         "o/x86_64/third_party/lua/lua",
         "o/x86_64/tool/build/apelink",
         "o/x86_64/ape/ape.elf"])
    run(["make", "MODE=aarch64", j,
         "o/aarch64/third_party/lua/lua",
         "o/aarch64/ape/ape.elf"])
    out = ROOT / "o/lua.com"
    run([ROOT / "o/x86_64/tool/build/apelink",
         "-l", "o/x86_64/ape/ape.elf",
         "-l", "o/aarch64/ape/ape.elf",
         "-M", "ape/ape-m1.c",
         "-o", out,
         "o/x86_64/third_party/lua/lua.dbg",
         "o/aarch64/third_party/lua/lua.dbg"])
    print("==> %s (%.1f MB)" % (out, out.stat().st_size / 1e6))


# ------------------------------------------------------------------ test

TEST_LUA = ROOT / "scripts/luaext_test.lua"


def run_test(label, argv):
    print("==> %s" % label)
    cmd = " ".join("'%s'" % a for a in argv)
    r = subprocess.run(["bash", "-c", cmd], cwd=ROOT)
    if r.returncode != 0:
        sys.exit("error: %s failed (exit %d)" % (label, r.returncode))


def test():
    t = TEST_LUA.relative_to(ROOT)
    run_test("x86_64 native (fat APE)", ["o/lua.com", str(t)])
    if shutil.which("qemu-aarch64"):
        run_test("aarch64 under qemu",
                 ["qemu-aarch64", "o/aarch64/third_party/lua/lua", str(t)])
    else:
        print("==> skipping aarch64: no qemu-aarch64 on PATH")
    if shutil.which("wine"):
        run_test("windows under wine", ["wine", "o/lua.com", str(t)])
    else:
        print("==> skipping windows: no wine on PATH")
    print("==> all tests passed")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("command",
                    choices=["vendor", "wire", "build", "test", "all"])
    args = ap.parse_args()
    if args.command in ("vendor", "all"):
        vendor_lfs()
        vendor_luaposix()
    if args.command in ("wire", "all"):
        wire()
    if args.command in ("build", "all"):
        build()
    if args.command in ("test", "all"):
        test()


if __name__ == "__main__":
    main()
