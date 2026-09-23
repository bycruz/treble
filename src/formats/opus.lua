-- Ogg Opus playback through libopusfile, which build.lua compiles in with libogg
-- and libopus.
local ffi = require("ffi")
local native = require("treble.native")
local Tags = require("treble.tags")

ffi.cdef([[
	typedef struct OggOpusFile OggOpusFile;

	typedef struct {
		char **user_comments;
		int *comment_lengths;
		int comments;
		char *vendor;
	} OpusTags;

	OggOpusFile *op_open_file(const char *path, int *error);
	OggOpusFile *op_open_memory(const unsigned char *data, size_t size, int *error);
	int op_read(OggOpusFile *of, short *pcm, int buf_size, int *li);
	int op_pcm_seek(OggOpusFile *of, long long pcm_offset);
	long long op_pcm_total(const OggOpusFile *of, int li);
	int op_channel_count(const OggOpusFile *of, int li);
	int op_seekable(const OggOpusFile *of);
	const OpusTags *op_tags(const OggOpusFile *of, int li);
	void op_free(OggOpusFile *of);
]])

-- Opus always decodes to this rate, whatever rate its input was encoded from.
local SAMPLE_RATE = 48000

local OP_EREAD = -128
local OP_ENOTFORMAT = -132
local OP_EINVAL = -131

---@param code number
local function errorMessage(code)
	if code == OP_EREAD then
		return "read failed"
	elseif code == OP_ENOTFORMAT then
		return "not an Ogg Opus stream"
	elseif code == OP_EINVAL then
		return "malformed stream"
	end

	return "opusfile error " .. code
end

---@class treble.formats.OpusSource: treble.Source
---@field tags treble.Tags?
---@field private file ffi.cdata*
---@field private link ffi.cdata* # op_read writes the link index here
local OpusSource = {}
OpusSource.__index = OpusSource

---@param file ffi.cdata*
---@return treble.formats.OpusSource
local function fromFile(file)
	local total = tonumber(native.lib.op_pcm_total(file, -1))

	---@type string[]
	local comments = {}
	local vendor = nil

	local tags = native.lib.op_tags(file, -1)
	if tags ~= nil then
		local list = tags[0]
		for i = 0, list.comments - 1 do
			local length = list.comment_lengths[i]
			if length > 0 then
				comments[#comments + 1] = ffi.string(list.user_comments[i], length)
			end
		end

		if list.vendor ~= nil then
			vendor = ffi.string(list.vendor)
		end
	end

	return setmetatable({
		tags = Tags.fromVorbisComments(comments, vendor),
		file = file,
		link = ffi.new("int[1]"),
		channels = native.lib.op_channel_count(file, -1),
		sampleRate = SAMPLE_RATE,
		-- A stream that cannot be measured reports no frame count.
		frameCount = total > 0 and total or 0,
	}, OpusSource)
end

--- Reads up to frames. A single call may give fewer, so read until it returns 0.
---@param out ffi.cdata*
---@param frames number
function OpusSource:read(out, frames)
	local read = native.lib.op_read(self.file, out, frames * self.channels, self.link)

	return read > 0 and read or 0
end

--- Seeking lands on the exact frame; the first samples after it come from a
--- decoder state that is still settling, which is normal for Opus.
---@param frame number
function OpusSource:seek(frame)
	return native.lib.op_pcm_seek(self.file, frame) == 0
end

function OpusSource:close()
	if self.file ~= nil then
		native.lib.op_free(self.file)
		self.file = nil
	end
end

local Opus = {}

---@param path string
---@return treble.formats.OpusSource? source
---@return string? err
function Opus.fromPath(path)
	local code = ffi.new("int[1]")
	local file = native.lib.op_open_file(path, code)
	if file == nil then
		return nil, "Failed to open Opus file: " .. errorMessage(code[0])
	end

	local source = fromFile(file)
	return source
end

--- Reads from memory that must stay alive until the source is closed.
---@param pointer ffi.cdata*
---@param size number
---@return treble.formats.OpusSource? source
---@return string? err
function Opus.fromMemory(pointer, size)
	local code = ffi.new("int[1]")
	local file = native.lib.op_open_memory(ffi.cast("const unsigned char*", pointer), size, code)
	if file == nil then
		return nil, "Failed to decode Opus data: " .. errorMessage(code[0])
	end

	local source = fromFile(file)
	return source
end

--- Reports whether the content is an Ogg page carrying an Opus header.
---@param content string
function Opus.isValid(content)
	return string.sub(content, 1, 4) == "OggS" and string.find(string.sub(content, 1, 64), "OpusHead", 1, true) ~= nil
end

return Opus
