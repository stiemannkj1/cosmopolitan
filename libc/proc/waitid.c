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
#include "libc/calls/cp.internal.h"
#include "libc/calls/struct/siginfo-meta.internal.h"
#include "libc/calls/struct/siginfo.h"
#include "libc/dce.h"
#include "libc/errno.h"
#include "libc/intrin/strace.h"
#include "libc/proc/proc.h"
#include "libc/str/str.h"
#include "libc/sysv/consts/sicode.h"
#include "libc/sysv/consts/sig.h"
#include "libc/sysv/consts/w.h"
#include "libc/sysv/consts/waitid.h"
#include "libc/sysv/errfuns.h"

int sys_waitid(int, unsigned, void *, int, void *);
int sys_wait6(int, unsigned, int *, int, void *, void *);

#define W_EXITSTATUS(s) (((s) >> 8) & 0xff)
#define W_TERMSIG(s)    ((s) & 0x7f)

// builds the siginfo a zombie would have produced from a wait status
static void waitid_fill(siginfo_t *info, int pid, int ws) {
  memset(info, 0, sizeof(*info));
  info->si_signo = SIGCHLD;
  info->si_pid = pid;
  if (W_TERMSIG(ws)) {
    info->si_code = (ws & 0x80) ? CLD_DUMPED : CLD_KILLED;
    info->si_status = W_TERMSIG(ws);
  } else {
    info->si_code = CLD_EXITED;
    info->si_status = W_EXITSTATUS(ws);
  }
}

static int waitid_bsd_idtype(int idtype) {
  if (IsFreebsd()) {
    return idtype == P_ALL ? 7 : idtype == P_PID ? 0 : 2;
  } else {
    return idtype == P_ALL ? 0 : idtype == P_PID ? 1 : 2;
  }
}

/**
 * Waits for status to change on child process, with optional peeking.
 *
 * Unlike waitpid(), this can look at a child that has exited without
 * reaping it, if WNOWAIT is passed. The child then stays waitable, so
 * a later waitpid() or waitid() without WNOWAIT still collects it.
 *
 * @param idtype is P_PID to wait for pid `id`, P_ALL to wait for any
 *     child (and `id` is ignored), or P_PGID to wait for any child in
 *     process group `id` (not supported on Windows)
 * @param info receives what happened. On success si_pid is the child
 *     id, or zero if WNOHANG was given and nothing has happened yet.
 *     Only si_signo (SIGCHLD), si_pid, si_code (CLD_EXITED, CLD_KILLED
 *     or CLD_DUMPED) and si_status (exit code or signal) are filled
 * @param options must have WEXITED, and may have WNOHANG and WNOWAIT.
 *     WSTOPPED and WCONTINUED are only supported on UNIX
 * @return 0 on success, or -1 w/ errno. ECHILD means the process is not
 *     a child of the caller (or was already reaped), ENOSYS is raised
 *     on OpenBSD, which has no way to peek at a zombie
 * @cancelationpoint
 * @asyncsignalsafe
 * @restartable
 */
int waitid(int idtype, unsigned id, siginfo_t *info, int options) {
  int rc;
  siginfo_t si;
  if (IsOpenbsd())
    return enosys();
  if (idtype != P_ALL && idtype != P_PID && idtype != P_PGID)
    return einval();
  if (!(options & WEXITED))
    return einval();
  if (options &
      ~(WEXITED | WSTOPPED | WCONTINUED | WNOHANG | WNOWAIT))
    return einval();
  memset(&si, 0, sizeof(si));
  BEGIN_CANCELATION_POINT;
  if (IsLinux()) {
    rc = sys_waitid(idtype, id, &si, options, 0);
  } else if (IsXnu()) {
    union siginfo_meta m;
    memset(&m, 0, sizeof(m));
    rc = sys_waitid(idtype, id, &m, options, 0);
    if (rc != -1 && m.xnu.si_pid)
      __siginfo2cosmo(&si, &m);
  } else if (IsFreebsd() || IsNetbsd()) {
    union siginfo_meta m;
    memset(&m, 0, sizeof(m));
    int ws = 0;
    rc = sys_wait6(waitid_bsd_idtype(idtype), id, &ws, options, 0, &m);
    if (rc > 0) {
      __siginfo2cosmo(&si, &m);
      if (!si.si_pid)
        waitid_fill(&si, rc, ws);
    }
    if (rc != -1)
      rc = 0;
  } else if (IsWindows()) {
    int ws = 0, pid;
    if (idtype == P_PGID || (options & (WSTOPPED | WCONTINUED))) {
      rc = einval();
    } else {
      pid = idtype == P_ALL ? -1 : (int)id;
      rc = sys_waitid_nt(pid, &ws, options & WNOHANG, !!(options & WNOWAIT));
      if (rc > 0) {
        waitid_fill(&si, rc, ws);
        rc = 0;
      } else if (rc == 0) {
        rc = 0;  // WNOHANG and no zombie
      }
    }
  } else {
    rc = enosys();
  }
  END_CANCELATION_POINT;
  if (rc != -1 && info)
    *info = si;
  STRACE("waitid(%d, %u, [pid=%d code=%d status=%d], %#x) → %d% m", idtype, id,
         si.si_pid, si.si_code, si.si_status, options, rc);
  return rc;
}
