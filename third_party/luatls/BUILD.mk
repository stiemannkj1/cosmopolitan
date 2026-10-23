#-*-mode:makefile-gmake;indent-tabs-mode:t;tab-width:8;coding:utf-8-*-┐
#── vi: set noet ft=make ts=8 sw=8 fenc=utf-8 :vi ───────────────────┘
#
# hand-written: this package is a reimplementation, not a vendored
# upstream, so scripts/luaext.py does not generate it

PKGS += THIRD_PARTY_LUATLS

THIRD_PARTY_LUATLS_ARTIFACTS += THIRD_PARTY_LUATLS_A
THIRD_PARTY_LUATLS = $(THIRD_PARTY_LUATLS_A_DEPS) $(THIRD_PARTY_LUATLS_A)
THIRD_PARTY_LUATLS_A = o/$(MODE)/third_party/luatls/luatls.a

THIRD_PARTY_LUATLS_A_HDRS =\
	third_party/luatls/ltlspreload.h

THIRD_PARTY_LUATLS_A_SRCS =\
	third_party/luatls/ltls.c \
	third_party/luatls/ltlsengine.c \
	third_party/luatls/notice.c

THIRD_PARTY_LUATLS_A_OBJS = $(THIRD_PARTY_LUATLS_A_SRCS:%.c=o/$(MODE)/%.o)

THIRD_PARTY_LUATLS_A_OK_HDRS =\
	third_party/luatls/ltlspreload.h

THIRD_PARTY_LUATLS_A_CHECKS =\
	$(THIRD_PARTY_LUATLS_A).pkg \
	$(THIRD_PARTY_LUATLS_A_OK_HDRS:%=o/$(MODE)/%.ok)

THIRD_PARTY_LUATLS_A_DIRECTDEPS =\
	LIBC_CALLS \
	LIBC_FMT \
	LIBC_INTRIN \
	LIBC_MEM \
	LIBC_NEXGEN32E \
	LIBC_RUNTIME \
	LIBC_SOCK \
	LIBC_STDIO \
	LIBC_STR \
	LIBC_SYSV \
	NET_HTTPS \
	THIRD_PARTY_MBEDTLS

THIRD_PARTY_LUATLS_A_DEPS :=\
	$(call uniq,$(foreach x,$(THIRD_PARTY_LUATLS_A_DIRECTDEPS),$($(x))))

$(THIRD_PARTY_LUATLS_A):\
	third_party/luatls/ \
	$(THIRD_PARTY_LUATLS_A).pkg \
	$(THIRD_PARTY_LUATLS_A_OBJS)

$(THIRD_PARTY_LUATLS_A).pkg:\
	$(THIRD_PARTY_LUATLS_A_OBJS) \
	o/$(MODE)/third_party/lua/lua.a.pkg \
	$(foreach x,$(THIRD_PARTY_LUATLS_A_DIRECTDEPS),$($(x)_A).pkg)

$(THIRD_PARTY_LUATLS_A_OBJS): private CFLAGS +=\
	-ffunction-sections \
	-fdata-sections

# the luaossl-shaped modules that sit on top of the engine
THIRD_PARTY_LUATLS_LUAS =\
	$(wildcard third_party/luatls/.lua/openssl/*.lua) \
	$(wildcard third_party/luatls/.lua/openssl/ssl/*.lua) \
	$(wildcard third_party/luatls/.lua/openssl/x509/*.lua)

THIRD_PARTY_LUATLS_ZIPOBJS =\
	$(THIRD_PARTY_LUATLS_LUAS:%=o/$(MODE)/%.zip.o)

$(THIRD_PARTY_LUATLS_ZIPOBJS): private ZIPOBJ_FLAGS +=\
	-C2

THIRD_PARTY_LUATLS_LIBS = $(foreach x,$(THIRD_PARTY_LUATLS_ARTIFACTS),$($(x)))
THIRD_PARTY_LUATLS_SRCS = $(foreach x,$(THIRD_PARTY_LUATLS_ARTIFACTS),$($(x)_SRCS))
THIRD_PARTY_LUATLS_HDRS = $(foreach x,$(THIRD_PARTY_LUATLS_ARTIFACTS),$($(x)_HDRS))
THIRD_PARTY_LUATLS_OBJS = $(foreach x,$(THIRD_PARTY_LUATLS_ARTIFACTS),$($(x)_OBJS))
THIRD_PARTY_LUATLS_CHECKS = $(foreach x,$(THIRD_PARTY_LUATLS_ARTIFACTS),$($(x)_CHECKS))
$(THIRD_PARTY_LUATLS_OBJS): third_party/luatls/BUILD.mk

.PHONY: o/$(MODE)/third_party/luatls
o/$(MODE)/third_party/luatls: $(THIRD_PARTY_LUATLS_CHECKS) $(THIRD_PARTY_LUATLS_ZIPOBJS)
