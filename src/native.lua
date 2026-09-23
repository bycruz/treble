local ffi = require("ffi")

local here = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or ""

--- The decoders build.lua compiles: dr_mp3, dr_flac, libogg, libopus and
--- libopusfile in one library.
---@class treble.native
---@field path string
---@field lib ffi.namespace*
local native = {}

local libname = jit.os == "Windows" and "decoders.dll" or "decoders.so"
local path = here .. libname

if io.open(path, "rb") == nil then
	error("The native decoders are missing from " .. here .. ". Run `lde install` to build them from build.lua.")
end

native.path = path
native.lib = ffi.load(path)

return native
