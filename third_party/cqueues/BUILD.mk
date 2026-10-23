#-*-mode:makefile-gmake;indent-tabs-mode:t;tab-width:8;coding:utf-8-*-┐
#── vi: set noet ft=make ts=8 sw=8 fenc=utf-8 :vi ───────────────────┘
#
# hand-written: this package is a reimplementation, not a vendored
# upstream, so scripts/luaext.py does not generate it

THIRD_PARTY_CQUEUES_LUAS =\
	$(wildcard third_party/cqueues/.lua/*.lua) \
	$(wildcard third_party/cqueues/.lua/cqueues/*.lua) \
	$(wildcard third_party/cqueues/.lua/cqueues/socket/*.lua)

THIRD_PARTY_CQUEUES_ZIPOBJS =\
	$(THIRD_PARTY_CQUEUES_LUAS:%=o/$(MODE)/%.zip.o)

# -C2 strips the leading third_party/cqueues/ from each zip entry name
$(THIRD_PARTY_CQUEUES_ZIPOBJS): private ZIPOBJ_FLAGS +=\
	-C2

.PHONY: o/$(MODE)/third_party/cqueues
o/$(MODE)/third_party/cqueues: $(THIRD_PARTY_CQUEUES_ZIPOBJS)
