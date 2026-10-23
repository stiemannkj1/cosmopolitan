/*-*- mode:c;indent-tabs-mode:nil;c-basic-offset:2;tab-width:8;coding:utf-8 -*-│
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
#define VERSION "36.3"

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
