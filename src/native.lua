local ffi = require("ffi")

--- Finds a shared library the way require would, by walking package.cpath.
---@param name string
---@return string? path
local function findLibrary(name)
	local modulePath = name:gsub("%.", "/")

	for template in package.cpath:gmatch("[^;]+") do
		local path = template:gsub("%?", modulePath)
		local file = io.open(path, "rb")
		if file then
			file:close()
			return path
		end
	end

	return nil
end

--- The decoders build.lua compiles: dr_mp3, libogg, libopus and libopusfile.
---@class treble.native
---@field path string
---@field lib ffi.namespace*
local native = {}

local path = findLibrary("treble.decoders")
if path == nil then
	error("The native decoders are missing. Run `lde install` to build them from build.lua.")
end

native.path = path
native.lib = ffi.load(path)

return native
