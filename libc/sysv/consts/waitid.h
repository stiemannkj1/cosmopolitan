#ifndef COSMOPOLITAN_LIBC_SYSV_CONSTS_WAITID_H_
#define COSMOPOLITAN_LIBC_SYSV_CONSTS_WAITID_H_
COSMOPOLITAN_C_START_

extern const int WEXITED;
extern const int WSTOPPED;
extern const int WNOWAIT;

/* idtype values for waitid(); cosmo translates them per operating system */
#define P_ALL  0
#define P_PID  1
#define P_PGID 2

#define WEXITED  WEXITED
#define WSTOPPED WSTOPPED
#define WNOWAIT  WNOWAIT

COSMOPOLITAN_C_END_
#endif /* COSMOPOLITAN_LIBC_SYSV_CONSTS_WAITID_H_ */
