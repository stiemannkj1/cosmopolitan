/*
 * POSIX library for Lua 5.1, 5.2, 5.3 & 5.4.
 * Copyright (C) 2013-2025 Gary V. Vaughan
 * Copyright (C) 2010-2013 Reuben Thomas <rrt@sc3d.org>
 * Copyright (C) 2008-2010 Natanael Copa <natanael.copa@gmail.com>
 * Clean up and bug fixes by Leo Razoumov <slonik.az@gmail.com> 2006-10-11
 * Luiz Henrique de Figueiredo <lhf@tecgraf.puc-rio.br> 07 Apr 2006 23:17:49
 * Based on original by Claudio Terra for Lua 3.x.
 * With contributions by Roberto Ierusalimschy.
 * With documentation from Steve Donovan 2012
 */

#include "third_party/luaposix/ctype.c"
#include "third_party/luaposix/dirent.c"
#include "third_party/luaposix/errno.c"
#include "third_party/luaposix/fcntl.c"
#include "third_party/luaposix/fnmatch.c"
#include "third_party/luaposix/glob.c"
#include "third_party/luaposix/grp.c"
#include "third_party/luaposix/libgen.c"
#include "third_party/luaposix/poll.c"
#include "third_party/luaposix/pwd.c"
#include "third_party/luaposix/sched.c"
#include "third_party/luaposix/signal.c"
#include "third_party/luaposix/stdio.c"
#include "third_party/luaposix/stdlib.c"
#include "third_party/luaposix/sys/msg.c"
#include "third_party/luaposix/sys/resource.c"
#include "third_party/luaposix/sys/socket.c"
#include "third_party/luaposix/sys/stat.c"
#include "third_party/luaposix/sys/statvfs.c"
#include "third_party/luaposix/sys/time.c"
#include "third_party/luaposix/sys/times.c"
#include "third_party/luaposix/sys/utsname.c"
#include "third_party/luaposix/sys/wait.c"
#include "third_party/luaposix/syslog.c"
#include "third_party/luaposix/termio.c"
#include "third_party/luaposix/time.c"
#include "third_party/luaposix/unistd.c"
#include "third_party/luaposix/utime.c"
