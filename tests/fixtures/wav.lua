local ffi = require("ffi")

local Uint16 = ffi.typeof("uint16_t[1]")
local Uint32 = ffi.typeof("uint32_t[1]")

local EXTENSIBLE = 0xFFFE

---@param value number
local function u16(value)
	return ffi.string(Uint16(value), 2)
end

---@param value number
local function u32(value)
	return ffi.string(Uint32(value), 4)
end

---@class tests.fixtures.wav.Opts
---@field channels number?
---@field sampleRate number?
---@field bitsPerSample number?
---@field audioFormat number?
---@field frames number?
---@field sampleBytes string? # Overrides the zeroed sample data
---@field dataSize number? # Overrides the size the data chunk claims
---@field extraChunk { id: string, size: number }? # Placed between the format and data chunks

--- Builds a RIFF file byte for byte, so tests need no audio file on disk.
local fixture = {}

---@param opts tests.fixtures.wav.Opts?
---@return string content
function fixture.build(opts)
	opts = opts or {}

	local channels = opts.channels or 1
	local sampleRate = opts.sampleRate or 8000
	local bitsPerSample = opts.bitsPerSample or 16
	local audioFormat = opts.audioFormat or 1
	local frames = opts.frames or 16

	local bytesPerFrame = channels * bitsPerSample / 8
	local sampleBytes = opts.sampleBytes or string.rep("\0", frames * bytesPerFrame)

	local format = "fmt "
		.. u32(16)
		.. u16(audioFormat)
		.. u16(channels)
		.. u32(sampleRate)
		.. u32(sampleRate * bytesPerFrame)
		.. u16(bytesPerFrame)
		.. u16(bitsPerSample)

	local extra = ""
	if opts.extraChunk then
		extra = opts.extraChunk.id .. u32(opts.extraChunk.size) .. string.rep("\0", opts.extraChunk.size)
	end

	-- An extensible header carries the real encoding in the GUID that follows.
	if audioFormat == EXTENSIBLE then
		format = "fmt "
			.. u32(40)
			.. u16(EXTENSIBLE)
			.. u16(channels)
			.. u32(sampleRate)
			.. u32(sampleRate * bytesPerFrame)
			.. u16(bytesPerFrame)
			.. u16(bitsPerSample)
			.. u16(22)
			.. u16(bitsPerSample)
			.. u32(0)
			.. u16(1)
			.. string.rep("\0", 14)
	end

	return "RIFF"
		.. u32(4 + #format + #extra + 8 + #sampleBytes)
		.. "WAVE"
		.. format
		.. extra
		.. "data"
		.. u32(opts.dataSize or #sampleBytes)
		.. sampleBytes
end

---@param opts tests.fixtures.wav.Opts?
---@return string content
function fixture.pcm16(opts)
	return fixture.build(opts)
end

return fixture
