#-*-mode:makefile-gmake;indent-tabs-mode:t;tab-width:8;coding:utf-8-*-┐
#── vi: set noet ft=make ts=8 sw=8 fenc=utf-8 :vi ───────────────────┘
#
# hand-written, unlike third_party/{lfs,luaposix,lpeg}/BUILD.mk, because
# this package is not vendored from anywhere

PKGS += THIRD_PARTY_LUAZLIB

THIRD_PARTY_LUAZLIB_ARTIFACTS += THIRD_PARTY_LUAZLIB_A
THIRD_PARTY_LUAZLIB = $(THIRD_PARTY_LUAZLIB_A_DEPS) $(THIRD_PARTY_LUAZLIB_A)
THIRD_PARTY_LUAZLIB_A = o/$(MODE)/third_party/luazlib/luazlib.a

THIRD_PARTY_LUAZLIB_A_HDRS =\
	third_party/luazlib/lzlibpreload.h

THIRD_PARTY_LUAZLIB_A_SRCS =\
	third_party/luazlib/lzlib.c \
	third_party/luazlib/notice.c

THIRD_PARTY_LUAZLIB_A_OBJS = $(THIRD_PARTY_LUAZLIB_A_SRCS:%.c=o/$(MODE)/%.o)

THIRD_PARTY_LUAZLIB_A_OK_HDRS =\
	third_party/luazlib/lzlibpreload.h

THIRD_PARTY_LUAZLIB_A_CHECKS =\
	$(THIRD_PARTY_LUAZLIB_A).pkg \
	$(THIRD_PARTY_LUAZLIB_A_OK_HDRS:%=o/$(MODE)/%.ok)

THIRD_PARTY_LUAZLIB_A_DIRECTDEPS =\
	LIBC_INTRIN \
	LIBC_MEM \
	LIBC_NEXGEN32E \
	LIBC_RUNTIME \
	LIBC_STR \
	THIRD_PARTY_ZLIB

THIRD_PARTY_LUAZLIB_A_DEPS :=\
	$(call uniq,$(foreach x,$(THIRD_PARTY_LUAZLIB_A_DIRECTDEPS),$($(x))))

$(THIRD_PARTY_LUAZLIB_A):\
	third_party/luazlib/ \
	$(THIRD_PARTY_LUAZLIB_A).pkg \
	$(THIRD_PARTY_LUAZLIB_A_OBJS)

$(THIRD_PARTY_LUAZLIB_A).pkg:\
	$(THIRD_PARTY_LUAZLIB_A_OBJS) \
	o/$(MODE)/third_party/lua/lua.a.pkg \
	$(foreach x,$(THIRD_PARTY_LUAZLIB_A_DIRECTDEPS),$($(x)_A).pkg)

$(THIRD_PARTY_LUAZLIB_A_OBJS): private CFLAGS +=\
	-ffunction-sections \
	-fdata-sections

THIRD_PARTY_LUAZLIB_LIBS = $(foreach x,$(THIRD_PARTY_LUAZLIB_ARTIFACTS),$($(x)))
THIRD_PARTY_LUAZLIB_SRCS = $(foreach x,$(THIRD_PARTY_LUAZLIB_ARTIFACTS),$($(x)_SRCS))
THIRD_PARTY_LUAZLIB_HDRS = $(foreach x,$(THIRD_PARTY_LUAZLIB_ARTIFACTS),$($(x)_HDRS))
THIRD_PARTY_LUAZLIB_OBJS = $(foreach x,$(THIRD_PARTY_LUAZLIB_ARTIFACTS),$($(x)_OBJS))
THIRD_PARTY_LUAZLIB_CHECKS = $(foreach x,$(THIRD_PARTY_LUAZLIB_ARTIFACTS),$($(x)_CHECKS))
$(THIRD_PARTY_LUAZLIB_OBJS): third_party/luazlib/BUILD.mk

.PHONY: o/$(MODE)/third_party/luazlib
o/$(MODE)/third_party/luazlib: $(THIRD_PARTY_LUAZLIB_CHECKS)
