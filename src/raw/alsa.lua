-- ALSA output for the player.
--
-- One stream stays open for as long as the player has something to play, and the
-- player only ever writes what snd_pcm_avail_update reports as writable, so the
-- caller never blocks.
local ffi = require("ffi")

ffi.cdef([[
	typedef void snd_pcm_t;
	typedef long snd_pcm_sframes_t;

	int snd_pcm_open(snd_pcm_t **pcm, const char *name, int stream, int mode);
	int snd_pcm_close(snd_pcm_t *pcm);
	int snd_pcm_set_params(
		snd_pcm_t *pcm,
		int format,
		int access,
		unsigned int channels,
		unsigned int rate,
		int soft_resample,
		unsigned int latency
	);
	snd_pcm_sframes_t snd_pcm_writei(snd_pcm_t *pcm, const void *buffer, unsigned int size);
	snd_pcm_sframes_t snd_pcm_avail_update(snd_pcm_t *pcm);
	int snd_pcm_delay(snd_pcm_t *pcm, snd_pcm_sframes_t *delayp);
	int snd_pcm_pause(snd_pcm_t *pcm, int enable);
	int snd_pcm_drop(snd_pcm_t *pcm);
	int snd_pcm_drain(snd_pcm_t *pcm);
	int snd_pcm_prepare(snd_pcm_t *pcm);
	int snd_pcm_state(snd_pcm_t *pcm);
	const char *snd_strerror(int errnum);
]])

---@class treble.ffi.pcm: ffi.cdata*

-- The versioned name is what the runtime ships; the unversioned "asound" only
-- exists when the development package is installed.
local asound = ffi.load("asound.so.2")

---@class treble.raw.alsa
---@field open fun(sampleRate: number, channels: number, device: string?): treble.OutputStream?, string?
local alsa = {}

local DEVICE = "default"

local SND_PCM_STREAM_PLAYBACK = 0
local SND_PCM_BLOCKING = 0
local SND_PCM_FORMAT_S16_LE = 2
local SND_PCM_ACCESS_RW_INTERLEAVED = 3
local SOFT_RESAMPLE = 1

local SND_PCM_STATE_RUNNING = 3
local SND_PCM_STATE_DRAINING = 5

-- Long enough that a busy frame does not starve the device, short enough that a
-- seek does not have a quarter second of stale audio to throw away.
local DEVICE_LATENCY_US = 150000

local PcmHandle = ffi.typeof("snd_pcm_t*[1]")
local DelayPointer = ffi.typeof("snd_pcm_sframes_t[1]")

---@class treble.raw.alsa.Stream: treble.OutputStream
---@field sampleRate number
---@field channels number
---@field private pcm treble.ffi.pcm
local Stream = {}
Stream.__index = Stream

--- Frames the device can take right now. An underrun leaves the stream in a
--- state that takes no writes, so it is prepared again here.
function Stream:avail()
	local frames = asound.snd_pcm_avail_update(self.pcm)
	if frames < 0 then
		asound.snd_pcm_prepare(self.pcm)
		frames = asound.snd_pcm_avail_update(self.pcm)
	end

	return frames > 0 and tonumber(frames) or 0
end

---@param samples ffi.cdata*
---@param frames number
function Stream:write(samples, frames)
	local written = asound.snd_pcm_writei(self.pcm, samples, frames)

	if written < 0 then
		-- An underrun (EPIPE) or a suspended device must not end playback: put the
		-- stream back in a writable state and try the same frames again.
		if asound.snd_pcm_prepare(self.pcm) < 0 then
			return 0
		end

		written = asound.snd_pcm_writei(self.pcm, samples, frames)
		if written < 0 then
			return 0
		end
	end

	return tonumber(written)
end

--- Frames handed to the device that have not been heard yet, which is what turns
--- written frames into a playback position.
---
--- A stream that is not running has nothing left to play, but the plugin can keep
--- reporting frames it never played: after an underrun it says the buffer is still
--- partly queued while the state sits at PREPARED. Only a running or draining
--- stream can be trusted to answer.
function Stream:delay()
	local state = asound.snd_pcm_state(self.pcm)
	if state ~= SND_PCM_STATE_RUNNING and state ~= SND_PCM_STATE_DRAINING then
		return 0
	end

	local delay = DelayPointer()
	if asound.snd_pcm_delay(self.pcm, delay) < 0 then
		return 0
	end

	return delay[0] > 0 and tonumber(delay[0]) or 0
end

--- Plays out what the device holds and then leaves it idle. This is what keeps the
--- tail of a short track from being dropped when nothing follows it.
function Stream:drain()
	asound.snd_pcm_drain(self.pcm)
end

---@param isPaused boolean
function Stream:setPaused(isPaused)
	asound.snd_pcm_pause(self.pcm, isPaused and 1 or 0)
end

--- Throws away what the device still holds, which is what a seek needs.
function Stream:flush()
	asound.snd_pcm_drop(self.pcm)
	asound.snd_pcm_prepare(self.pcm)
end

function Stream:close()
	if self.pcm ~= nil then
		asound.snd_pcm_close(self.pcm)
		self.pcm = nil
	end
end

---@param sampleRate number
---@param channels number
---@param device string? # An ALSA device name, such as "hw:1,0", or the default
---@return treble.raw.alsa.Stream? stream
---@return string? err
function alsa.open(sampleRate, channels, device)
	local handle = PcmHandle()
	local err = asound.snd_pcm_open(handle, device or DEVICE, SND_PCM_STREAM_PLAYBACK, SND_PCM_BLOCKING)
	if err < 0 then
		return nil, "Failed to open the PCM device: " .. ffi.string(asound.snd_strerror(err))
	end

	---@type treble.ffi.pcm
	local pcm = handle[0]

	-- Soft resampling lets one device follow whatever rate a track uses.
	err = asound.snd_pcm_set_params(
		pcm,
		SND_PCM_FORMAT_S16_LE,
		SND_PCM_ACCESS_RW_INTERLEAVED,
		channels,
		sampleRate,
		SOFT_RESAMPLE,
		DEVICE_LATENCY_US
	)
	if err < 0 then
		asound.snd_pcm_close(pcm)
		return nil, "Failed to set the PCM parameters: " .. ffi.string(asound.snd_strerror(err))
	end

	local stream = setmetatable({ pcm = pcm, sampleRate = sampleRate, channels = channels }, Stream)
	return stream
end

return alsa
