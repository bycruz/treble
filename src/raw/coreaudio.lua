-- macOS output through CoreAudio, by way of the AudioUnit shim in src/native.
--
-- The render callback runs on the audio thread and only touches the shim's ring
-- buffer, so this side stays a push model like the other backends: ask how much
-- fits, write that much, and read the position back from the frames still queued.
local ffi = require("ffi")
local native = require("treble.native")

ffi.cdef([[
	int usleep(unsigned int microseconds);

	void *treble_core_open(double sampleRate, unsigned int channels, unsigned int deviceId);
	void treble_core_start(void *handle);
	void treble_core_stop(void *handle);
	unsigned int treble_core_avail(const void *handle);
	unsigned int treble_core_delay(const void *handle);
	unsigned int treble_core_write(void *handle, const short *samples, unsigned int frames);
	void treble_core_flush(void *handle);
	void treble_core_close(void *handle);
]])

---@class treble.raw.coreaudio
---@field open fun(sampleRate: number, channels: number, device: string?): treble.OutputStream?, string?
local coreaudio = {}

---@class treble.raw.coreaudio.Stream: treble.OutputStream
---@field sampleRate number
---@field channels number
---@field private handle ffi.cdata*
---@field private isPaused boolean
local Stream = {}
Stream.__index = Stream

--- Frames the shim can take right now.
function Stream:avail()
	return native.lib.treble_core_avail(self.handle)
end

---@param samples ffi.cdata*
---@param frames number
function Stream:write(samples, frames)
	return native.lib.treble_core_write(self.handle, samples, frames)
end

--- Frames pushed in but not heard yet, which is the playback position's clock.
function Stream:delay()
	return native.lib.treble_core_delay(self.handle)
end

---@param isPaused boolean
function Stream:setPaused(isPaused)
	self.isPaused = isPaused

	if isPaused then
		native.lib.treble_core_stop(self.handle)
	else
		native.lib.treble_core_start(self.handle)
	end
end

--- Drops what is queued, which is what a seek or a skip needs.
function Stream:flush()
	native.lib.treble_core_flush(self.handle)
end

--- Waits for what is queued to be rendered, so a track's tail is not cut off.
function Stream:drain()
	local waited = 0

	while native.lib.treble_core_delay(self.handle) > 0 and waited < 1000 do
		ffi.C.usleep(5000)
		waited = waited + 5
	end
end

function Stream:close()
	if self.handle ~= nil then
		native.lib.treble_core_close(self.handle)
		self.handle = nil
	end
end

---@param sampleRate number
---@param channels number
---@param device string? # An AudioDeviceID to render to, or the default output
---@return treble.raw.coreaudio.Stream? stream
---@return string? err
function coreaudio.open(sampleRate, channels, device)
	local deviceId = 0
	if device == "none" then
		-- No device behind it, which is how the backend is exercised on a machine
		-- without audio hardware.
		deviceId = 0xFFFFFFFF
	elseif device ~= nil and device ~= "" then
		deviceId = tonumber(device) or 0
	end

	local handle = native.lib.treble_core_open(sampleRate, channels, deviceId)
	if handle == nil then
		return nil, "Failed to open the default output device"
	end

	native.lib.treble_core_start(handle)

	---@type treble.raw.coreaudio.Stream
	local stream = setmetatable({
		handle = handle,
		sampleRate = sampleRate,
		channels = channels,
		isPaused = false,
	}, Stream)

	return stream
end

return coreaudio
