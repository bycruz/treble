-- MP3 playback through dr_mp3, which build.lua compiles into the native library.
local ffi = require("ffi")
local native = require("treble.native")
local Tags = require("treble.tags")

ffi.cdef([[
	void *treble_mp3_open_file(const char *path);
	void *treble_mp3_open_memory(const void *data, size_t size);
	unsigned int treble_mp3_channels(const void *handle);
	unsigned int treble_mp3_sample_rate(const void *handle);
	unsigned long long treble_mp3_frame_count(const void *handle);
	unsigned long long treble_mp3_read_s16(void *handle, short *out, unsigned long long frames);
	unsigned int treble_mp3_seek(void *handle, unsigned long long frame);
	void treble_mp3_close(void *handle);
	unsigned int treble_mp3_tag_kind(const void *handle);
	const unsigned char *treble_mp3_tag_data(const void *handle);
	unsigned long long treble_mp3_tag_size(const void *handle);
]])

---@class treble.formats.Mp3Source: treble.Source
---@field private handle ffi.cdata*
---@field tags treble.Tags?
local Mp3Source = {}
Mp3Source.__index = Mp3Source

---@param handle ffi.cdata*
---@return treble.formats.Mp3Source
function Mp3Source.new(handle)
	local lib = native.lib
	local kind = lib.treble_mp3_tag_kind(handle)

	---@type treble.Tags?
	local tags = nil
	if kind ~= 0 then
		local size = tonumber(lib.treble_mp3_tag_size(handle))
		local raw = ffi.string(lib.treble_mp3_tag_data(handle), size)

		tags = kind == 2 and Tags.fromId3v2(raw) or Tags.fromId3v1(raw)
	end

	return setmetatable({
		handle = handle,
		tags = tags,
		channels = lib.treble_mp3_channels(handle),
		sampleRate = lib.treble_mp3_sample_rate(handle),
		frameCount = tonumber(lib.treble_mp3_frame_count(handle)),
	}, Mp3Source)
end

---@param out ffi.cdata*
---@param frames number
function Mp3Source:read(out, frames)
	return tonumber(native.lib.treble_mp3_read_s16(self.handle, out, frames))
end

---@param frame number
function Mp3Source:seek(frame)
	return native.lib.treble_mp3_seek(self.handle, frame) == 1
end

function Mp3Source:close()
	if self.handle ~= nil then
		native.lib.treble_mp3_close(self.handle)
		self.handle = nil
	end
end

local Mp3 = {}

---@param path string
---@return treble.formats.Mp3Source? source
---@return string? err
function Mp3.fromPath(path)
	local handle = native.lib.treble_mp3_open_file(path)
	if handle == nil then
		return nil, "Failed to open MP3 file: " .. path
	end

	local source = Mp3Source.new(handle)
	return source
end

--- Reads from memory that must stay alive until the source is closed.
---@param pointer ffi.cdata*
---@param size number
---@return treble.formats.Mp3Source? source
---@return string? err
function Mp3.fromMemory(pointer, size)
	local handle = native.lib.treble_mp3_open_memory(pointer, size)
	if handle == nil then
		return nil, "Failed to decode MP3 data"
	end

	local source = Mp3Source.new(handle)
	return source
end

--- Reports whether the content starts with an MP3 frame or an ID3 tag.
---@param content string
function Mp3.isValid(content)
	if string.sub(content, 1, 3) == "ID3" then
		return true
	end

	local first, second = string.byte(content, 1, 2)

	return first == 0xFF and second ~= nil and second >= 0xE0
end

return Mp3
