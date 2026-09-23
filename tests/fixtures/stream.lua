local ffi = require("ffi")

local Int16 = ffi.typeof("int16_t[?]")

--- A stand in for a backend stream. It records every frame it is handed and lets a
--- test decide when the "device" has heard them.
---@class tests.FakeStream: treble.OutputStream
---@field sampleRate number
---@field channels number
---@field capacity number # Frames the device holds before it is full
---@field queued number # Frames written but not heard yet
---@field written ffi.cdata*
---@field writtenFrames number
---@field flushes number
---@field drains number
---@field isPaused boolean
---@field isClosed boolean
---@field isBlocking boolean # Accepts any amount, like a blocking device
local FakeStream = {}
FakeStream.__index = FakeStream

---@class tests.FakeStream.Opts
---@field capacity number? # Frames the device can hold before it is full
---@field total number? # Frames the stream will accept over its life
---@field isBlocking boolean?

---@param sampleRate number
---@param channels number
---@param opts tests.FakeStream.Opts?
---@return tests.FakeStream
function FakeStream.new(sampleRate, channels, opts)
	opts = opts or {}

	local capacity = opts.capacity or 4410
	local total = opts.total or 44100

	return setmetatable({
		sampleRate = sampleRate,
		channels = channels,
		capacity = capacity,
		queued = 0,
		written = Int16(total * channels),
		writtenFrames = 0,
		flushes = 0,
		drains = 0,
		isPaused = false,
		isClosed = false,
		isBlocking = opts.isBlocking or false,
	}, FakeStream)
end

--- Plays frames, as a device would over time.
---@param frames number
function FakeStream:play(frames)
	self.queued = math.max(0, self.queued - frames)
end

function FakeStream:avail()
	if self.isPaused then
		return 0
	end

	return math.max(0, self.capacity - self.queued)
end

---@param samples ffi.cdata*
---@param frames number
function FakeStream:write(samples, frames)
	local room = self.isBlocking and frames or math.min(self:avail(), frames)
	if room == 0 then
		return 0
	end

	ffi.copy(self.written + self.writtenFrames * self.channels, samples, room * self.channels * 2)
	self.writtenFrames = self.writtenFrames + room
	self.queued = self.queued + room

	return room
end

function FakeStream:delay()
	return self.queued
end

---@param isPaused boolean
function FakeStream:setPaused(isPaused)
	self.isPaused = isPaused
end

--- Plays out the tail, as a draining device would.
function FakeStream:drain()
	self.drains = self.drains + 1
	self.queued = 0
end

function FakeStream:flush()
	self.queued = 0
	self.flushes = self.flushes + 1
end

function FakeStream:close()
	self.isClosed = true
end

return FakeStream
