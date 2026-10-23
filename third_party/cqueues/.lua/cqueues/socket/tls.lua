--[[ The bridge between an openssl.ssl.context, which is a record of what
     the caller asked for, and the mbedtls engine in third_party/luatls.

     Everything awkward about translating the OpenSSL API lives here
     rather than in C, because this is where it is easy to read and to
     correct. ]]
local tls = require '_cosmo_tls'
local ctxlib = require 'openssl.ssl.context'

local M = {}

--[[ jart's mbedtls fork names its ciphersuites with OpenSSL spellings
     rather than the usual mbedtls ones, so "ECDHE-ECDSA-AES256-GCM-SHA384"
     is already the right string.  Two spellings differ mechanically: the
     ChaCha20 suites carry a -SHA256 suffix OpenSSL omits, and the CBC
     suites spell CBC out.  Normalising those two makes Mozilla's modern
     list resolve completely. ]]
local function candidates(name)
   local out = {name}
   if name:find('CHACHA20%-POLY1305$') then
      out[#out + 1] = name .. '-SHA256'
   end
   local head, hash = name:match '^(.*%-AES%d+)%-(SHA%d*)$'
   if head then
      out[#out + 1] = head .. '-CBC-' .. hash
   end
   return out
end

--[[ OpenSSL cipher strings are a query language, with grouping atoms
     like HIGH and exclusions like !aNULL.  mbedtls has no equivalent, so
     concrete suite names are translated and everything else is dropped.
     A list that resolves to nothing is an error rather than a silent
     fallback to mbedtls' defaults. ]]
local function cipher_list(spec)
   if spec == nil then
      return nil
   end
   local names, seen = {}, {}
   local dropped = 0
   for atom in spec:gmatch '[^:]+' do
      if atom:match '^[!%-+@]' or atom:find('%+')
         or atom == 'HIGH' or atom == 'MEDIUM' or atom == 'LOW'
         or atom == 'AES' or atom == 'SEED' or atom == 'ALL'
         or atom == 'DEFAULT' or atom == 'COMPLEMENTOFDEFAULT' then
         dropped = dropped + 1
      else
         for _, c in ipairs(candidates(atom)) do
            if not seen[c] then
               seen[c] = true
               names[#names + 1] = c
            end
         end
      end
   end
   if #names == 0 then
      return nil, 'no cipher in the list is available in mbedtls'
   end
   return names
end

local function curve_list(spec)
   if spec == nil then
      return nil
   end
   local out = {}
   for atom in spec:gmatch '[^:%s]+' do
      out[#out + 1] = atom
   end
   return out
end

--[[ OpenSSL expresses a version floor by switching old versions off.
     This mbedtls does TLS 1.2 and nothing newer, so the only question
     worth asking is whether 1.0 and 1.1 are excluded. ]]
local function tls12only(options)
   if options == nil then
      return false
   end
   local no_tls1 = (options & ctxlib.OP_NO_TLSv1) ~= 0
   local no_tls11 = (options & ctxlib.OP_NO_TLSv1_1) ~= 0
   return no_tls1 and no_tls11
end

function M.wrap(sock, ctx)
   local cfg = {fd = sock.fd, server = false}
   if ctx ~= nil then
      cfg.server = ctx.server and true or false
      cfg.tls12only = tls12only(ctx.options)
      local ciphers, err = cipher_list(ctx.ciphers)
      if ciphers == nil and ctx.ciphers ~= nil then
         return nil, err
      end
      cfg.ciphers = ciphers
      cfg.curves = curve_list(ctx.groups)
      cfg.alpn = ctx.alpn
      if ctx.verify and ctx.verify ~= ctxlib.VERIFY_NONE then
         cfg.authmode = tls.VERIFY_REQUIRED
      else
         cfg.authmode = tls.VERIFY_NONE
      end
      cfg.cadefaults = ctx.store and ctx.store.defaults or false
      cfg.hostname = ctx.hostname
      local param = ctx.param
      if cfg.hostname == nil and param then
         cfg.hostname = param.host or param.ip
      end
   end
   if cfg.hostname == nil and sock.sendname then
      cfg.hostname = sock.sendname
   end
   local engine, msg = tls.engine(cfg)
   if engine == nil then
      return nil, msg
   end
   return engine
end

return M
