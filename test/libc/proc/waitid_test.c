/*-*- mode:c;indent-tabs-mode:nil;c-basic-offset:2;tab-width:8;coding:utf-8 -*-│
│ vi: set et ft=c ts=2 sts=2 sw=2 fenc=utf-8                               :vi │
╞══════════════════════════════════════════════════════════════════════════════╡
│ Copyright 2025 Justine Alexandra Roberts Tunney                              │
│                                                                              │
│ Permission to use, copy, modify, and/or distribute this software for         │
│ any purpose with or without fee is hereby granted, provided that the         │
│ above copyright notice and this permission notice appear in all copies.      │
│                                                                              │
│ THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL                │
│ WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED                │
│ WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE             │
│ AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL         │
│ DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR        │
│ PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER               │
│ TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR             │
│ PERFORMANCE OF THIS SOFTWARE.                                                │
╚─────────────────────────────────────────────────────────────────────────────*/
#include "libc/calls/calls.h"
#include "libc/calls/struct/siginfo.h"
#include "libc/dce.h"
#include "libc/errno.h"
#include "libc/runtime/runtime.h"
#include "libc/str/str.h"
#include "libc/sysv/consts/sicode.h"
#include "libc/sysv/consts/sig.h"
#include "libc/sysv/consts/w.h"
#include "libc/sysv/consts/waitid.h"
#include "libc/testlib/testlib.h"

#define PEEK (WEXITED | WNOWAIT)

// forks a child that exits with `code`. if gate is non-null, then the
// child first blocks until the parent writes to *gate (or closes it).
static int Spawn(int code, int *gate) {
  int pid, fds[2];
  if (gate)
    ASSERT_SYS(0, 0, pipe(fds));
  ASSERT_NE(-1, (pid = fork()));
  if (!pid) {
    if (gate) {
      char c;
      close(fds[1]);
      read(fds[0], &c, 1);
    }
    _exit(code);
  }
  if (gate) {
    close(fds[0]);
    *gate = fds[1];
  }
  return pid;
}

static void Release(int gate) {
  ASSERT_SYS(0, 1, write(gate, "x", 1));
  ASSERT_SYS(0, 0, close(gate));
}

TEST(waitid, peekDoesNotReap) {
  if (IsOpenbsd())
    return;
  siginfo_t si;
  int pid = Spawn(7, 0);
  ASSERT_SYS(0, 0, waitid(P_PID, pid, &si, PEEK));
  EXPECT_EQ(pid, si.si_pid);
  EXPECT_EQ(CLD_EXITED, si.si_code);
  EXPECT_EQ(7, si.si_status);
  EXPECT_EQ(SIGCHLD, si.si_signo);
  // still there, any number of times
  ASSERT_SYS(0, 0, waitid(P_PID, pid, &si, PEEK));
  EXPECT_EQ(pid, si.si_pid);
  EXPECT_EQ(7, si.si_status);
  ASSERT_SYS(0, 0, waitid(P_ALL, 0, &si, PEEK | WNOHANG));
  EXPECT_EQ(pid, si.si_pid);
  // waitpid can still collect it
  int ws;
  ASSERT_SYS(0, pid, waitpid(pid, &ws, 0));
  EXPECT_TRUE(WIFEXITED(ws));
  EXPECT_EQ(7, WEXITSTATUS(ws));
  // and now it's gone
  ASSERT_SYS(ECHILD, -1, waitid(P_PID, pid, &si, PEEK));
  ASSERT_SYS(ECHILD, -1, waitid(P_PID, pid, &si, WEXITED));
}

TEST(waitid, withoutNowaitReaps) {
  if (IsOpenbsd())
    return;
  siginfo_t si;
  int pid = Spawn(3, 0);
  ASSERT_SYS(0, 0, waitid(P_PID, pid, &si, WEXITED));
  EXPECT_EQ(pid, si.si_pid);
  EXPECT_EQ(CLD_EXITED, si.si_code);
  EXPECT_EQ(3, si.si_status);
  ASSERT_SYS(ECHILD, -1, waitid(P_PID, pid, &si, WEXITED));
  ASSERT_SYS(ECHILD, -1, waitpid(pid, 0, 0));
}

TEST(waitid, nohang_reportsStillRunning) {
  if (IsOpenbsd())
    return;
  siginfo_t si;
  int gate;
  int pid = Spawn(0, &gate);
  memset(&si, 0x55, sizeof(si));
  ASSERT_SYS(0, 0, waitid(P_PID, pid, &si, PEEK | WNOHANG));
  EXPECT_EQ(0, si.si_pid);
  Release(gate);
  // blocking peek wakes up when it exits
  memset(&si, 0x55, sizeof(si));
  ASSERT_SYS(0, 0, waitid(P_PID, pid, &si, PEEK));
  EXPECT_EQ(pid, si.si_pid);
  EXPECT_EQ(0, si.si_status);
  ASSERT_SYS(0, 0, waitid(P_PID, pid, &si, WEXITED));
  ASSERT_SYS(ECHILD, -1, waitid(P_PID, pid, &si, WEXITED | WNOHANG));
}

TEST(waitid, killedBySignal) {
  if (IsOpenbsd())
    return;
  siginfo_t si;
  int gate;
  int pid = Spawn(0, &gate);
  ASSERT_SYS(0, 0, waitid(P_PID, pid, &si, PEEK | WNOHANG));
  EXPECT_EQ(0, si.si_pid);
  ASSERT_SYS(0, 0, kill(pid, SIGKILL));
  // peek after the process is already dead, with no timeout
  ASSERT_SYS(0, 0, waitid(P_PID, pid, &si, PEEK));
  EXPECT_EQ(pid, si.si_pid);
  EXPECT_EQ(CLD_KILLED, si.si_code);
  EXPECT_EQ(SIGKILL, si.si_status);
  ASSERT_SYS(0, 0, waitid(P_PID, pid, &si, WEXITED));
  close(gate);
}

TEST(waitid, killedLongBeforeWait) {
  if (IsOpenbsd())
    return;
  siginfo_t si;
  int gate;
  int pid = Spawn(0, &gate);
  ASSERT_SYS(0, 0, kill(pid, SIGKILL));
  usleep(200000);
  ASSERT_SYS(0, 0, waitid(P_PID, pid, &si, PEEK));
  EXPECT_EQ(pid, si.si_pid);
  EXPECT_EQ(SIGKILL, si.si_status);
  ASSERT_SYS(0, 0, waitid(P_PID, pid, &si, WEXITED));
  close(gate);
}

TEST(waitid, notOurChild) {
  if (IsOpenbsd())
    return;
  siginfo_t si;
  // pid 1 and ourselves are never our children
  ASSERT_SYS(ECHILD, -1, waitid(P_PID, 1, &si, WEXITED | WNOHANG));
  ASSERT_SYS(ECHILD, -1, waitid(P_PID, getpid(), &si, WEXITED | WNOHANG));
}

TEST(waitid, forkedCopyDoesNotOwnSiblings) {
  if (IsOpenbsd() || IsWindows())
    return;
  siginfo_t si;
  int gate;
  int pid = Spawn(0, &gate);
  int pid2;
  ASSERT_NE(-1, (pid2 = fork()));
  if (!pid2) {
    // the new process is not the parent of pid
    _exit(waitid(P_PID, pid, &si, WEXITED | WNOHANG) == -1 && errno == ECHILD
              ? 0
              : 1);
  }
  int ws;
  ASSERT_SYS(0, pid2, waitpid(pid2, &ws, 0));
  EXPECT_EQ(0, WEXITSTATUS(ws));
  Release(gate);
  ASSERT_SYS(0, 0, waitid(P_PID, pid, &si, WEXITED));
}

TEST(waitid, badArguments) {
  if (IsOpenbsd())
    return;
  siginfo_t si;
  int pid = Spawn(0, 0);
  ASSERT_SYS(EINVAL, -1, waitid(77, pid, &si, WEXITED));
  ASSERT_SYS(EINVAL, -1, waitid(P_PID, pid, &si, 0));
  ASSERT_SYS(EINVAL, -1, waitid(P_PID, pid, &si, WNOWAIT));
  ASSERT_SYS(EINVAL, -1, waitid(P_PID, pid, &si, WEXITED | 0x40000000));
  ASSERT_SYS(0, 0, waitid(P_PID, pid, &si, WEXITED));
}

TEST(waitid, openbsdIsUnsupported) {
  if (!IsOpenbsd())
    return;
  siginfo_t si;
  ASSERT_SYS(ENOSYS, -1, waitid(P_ALL, 0, &si, WEXITED | WNOHANG));
}
