-- Where the player sends audio.
--
-- A backend opens one stream per sample rate and channel count and keeps it open
-- while there is something to play. Nothing here blocks: the player asks how much
-- the device can take and writes only that.

---@class treble.OutputStream
---@field sampleRate number
---@field channels number
---@field write fun(self: treble.OutputStream, samples: ffi.cdata*, frames: number): number
---@field avail fun(self: treble.OutputStream): number
---@field delay fun(self: treble.OutputStream): number # Frames written but not heard yet
---@field setPaused fun(self: treble.OutputStream, isPaused: boolean)
---@field drain fun(self: treble.OutputStream) # Plays out what the device holds
---@field flush fun(self: treble.OutputStream) # Drops what the device still holds
---@field close fun(self: treble.OutputStream)

--- The playback backend of the running platform.
---@class treble.raw
---@field open fun(sampleRate: number, channels: number, device: string?): treble.OutputStream?, string?

local output = (
	jit.os == "Linux" and require("treble.raw.alsa")
	or jit.os == "Windows" and require("treble.raw.wasapi")
	or jit.os == "OSX" and require("treble.raw.coreaudio")
	or error("Unsupported OS for audio playback: " .. jit.os)
) --[[@as treble.raw]]

return output
