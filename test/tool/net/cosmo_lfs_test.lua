-- Runs the shared LuaFileSystem suite against redbean's cosmo-lfs.
--
-- The cases live in scripts/luaext_test.lua, which also serves the lua APE
-- and its C lfs and luaposix, so this wrapper only points redbean at it.
-- Under redbean the luaposix groups report as unsupported and the lfs
-- groups run. The suite exits nonzero only when something failed.

local root = arg[0]:gsub('test/tool/net/[^/\\]*$', '')
dofile(root .. 'scripts/luaext_test.lua')
