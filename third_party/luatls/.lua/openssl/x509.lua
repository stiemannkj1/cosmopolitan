--[[ openssl.x509, shaped for lua-http over mbedtls.

     Only the read side is meaningful here: a certificate the engine
     handed back from a completed handshake.  Building a certificate,
     which lua-http's server does when asked to invent a self-signed one,
     is not implemented, so those setters record and the eventual sign()
     refuses rather than producing something unusable. ]]
local methods = {}
local mt = {__index = methods, __name = 'openssl.x509'}

local M = {}

function M.new(pem)
   return setmetatable({pem = pem, fields = {}}, mt)
end

function M.interpose()
   return nil
end

local function recorder(field)
   return function(self, v)
      self.fields[field] = v
      return true
   end
end

methods.setVersion = recorder 'version'
methods.setSerial = recorder 'serial'
methods.setSubject = recorder 'subject'
methods.setIssuer = recorder 'issuer'
methods.setPublicKey = recorder 'pubkey'
methods.setSubjectAlt = recorder 'altname'
methods.setBasicConstraints = recorder 'basic'
methods.setBasicConstraintsCritical = recorder 'basic_critical'

function methods:setLifetime(from, to)
   self.fields.from, self.fields.to = from, to
   return true
end

function methods:sign()
   return nil, 'certificate generation is not implemented by the mbedtls shim'
end

function methods:getSubject()
   return self.subject
end

function methods:getSubjectAlt()
   return self.altname
end

function methods:getLifetime()
   return self.notbefore, self.notafter
end

function methods:toPEM()
   return self.pem
end

return M
