-- FLAC playback through dr_flac, which build.lua compiles into the native library.
local ffi = require("ffi")
local native = require("treble.native")
local Tags = require("treble.tags")

ffi.cdef([[
	void *treble_flac_open_file(const char *path);
	void *treble_flac_open_memory(const void *data, size_t size);
	unsigned int treble_flac_channels(const void *handle);
	unsigned int treble_flac_sample_rate(const void *handle);
	unsigned long long treble_flac_frame_count(const void *handle);
	unsigned long long treble_flac_read_s16(void *handle, short *out, unsigned long long frames);
	unsigned int treble_flac_seek(void *handle, unsigned long long frame);
	void treble_flac_close(void *handle);
	const unsigned char *treble_flac_comments(const void *handle);
	unsigned int treble_flac_comment_count(const void *handle);
	unsigned long long treble_flac_comment_size(const void *handle);
	const char *treble_flac_vendor(const void *handle);
	const char *treble_flac_picture_mime(const void *handle);
	const char *treble_flac_picture_description(const void *handle);
	const unsigned char *treble_flac_picture_data(const void *handle);
	unsigned long long treble_flac_picture_size(const void *handle);
]])

---@class treble.formats.FlacSource: treble.Source
---@field tags treble.Tags?
---@field private handle ffi.cdata*
local FlacSource = {}
FlacSource.__index = FlacSource

---@param handle ffi.cdata*
---@return treble.formats.FlacSource
function FlacSource.new(handle)
	local lib = native.lib

	---@type treble.Tags?
	local tags = nil
	local comments = lib.treble_flac_comments(handle)
	local count = lib.treble_flac_comment_count(handle)

	if comments ~= nil and count > 0 then
		local vendor = lib.treble_flac_vendor(handle)
		local packed = ffi.string(comments, tonumber(lib.treble_flac_comment_size(handle)))

		tags = Tags.fromFlacComments(packed, count, vendor ~= nil and ffi.string(vendor) or nil)
	end

	local pictureMime = lib.treble_flac_picture_mime(handle)
	local pictureData = lib.treble_flac_picture_data(handle)
	if pictureMime ~= nil and pictureData ~= nil then
		local description = lib.treble_flac_picture_description(handle)
		local size = tonumber(lib.treble_flac_picture_size(handle))

		tags = tags or {}
		tags.picture = Tags.fromPicture(
			ffi.string(pictureMime),
			description ~= nil and ffi.string(description) or nil,
			ffi.string(pictureData, size)
		)
	end

	return setmetatable({
		tags = tags,
		handle = handle,
		channels = lib.treble_flac_channels(handle),
		sampleRate = lib.treble_flac_sample_rate(handle),
		frameCount = tonumber(lib.treble_flac_frame_count(handle)),
	}, FlacSource)
end

---@param out ffi.cdata*
---@param frames number
---@return number? frames
---@return string? err
function FlacSource:read(out, frames)
	local read = tonumber(native.lib.treble_flac_read_s16(self.handle, out, frames))

	if read == 0 and frames > 0 then
		return nil, "Failed to decode FLAC data"
	end

	return read
end

---@param frame number
---@return boolean
function FlacSource:seek(frame)
	return native.lib.treble_flac_seek(self.handle, frame) == 1
end

function FlacSource:close()
	if self.handle ~= nil then
		native.lib.treble_flac_close(self.handle)
		self.handle = nil
	end
end

local Flac = {}

---@param path string
---@return treble.formats.FlacSource? source
---@return string? err
function Flac.fromPath(path)
	local handle = native.lib.treble_flac_open_file(path)
	if handle == nil then
		return nil, "Failed to open FLAC file: " .. path
	end

	local source = FlacSource.new(handle)
	return source
end

--- Reads from memory that must stay alive until the source is closed.
---@param pointer ffi.cdata*
---@param size number
---@return treble.formats.FlacSource? source
---@return string? err
function Flac.fromMemory(pointer, size)
	local handle = native.lib.treble_flac_open_memory(pointer, size)
	if handle == nil then
		return nil, "Failed to decode FLAC data"
	end

	local source = FlacSource.new(handle)
	return source
end

--- Reports whether the content starts with the FLAC stream marker.
---@param content string
function Flac.isValid(content)
	return string.sub(content, 1, 4) == "fLaC"
end

return Flac
