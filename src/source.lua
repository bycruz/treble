-- The decoder contract the playback backends read from.
--
-- A source hands out signed 16 bit frames on demand so nothing has to hold a
-- whole decoded track in memory. It is a shape, not a base class: each format
-- module returns a table with these fields.

---@class treble.Source
---@field channels number
---@field sampleRate number
---@field frameCount number # Frames per channel, 0 when the format cannot say
---@field tags treble.Tags? # What the file says about itself, when it says anything
---@field read fun(self: treble.Source, out: ffi.cdata*, frames: number): number
---@field seek fun(self: treble.Source, frame: number): boolean
---@field close fun(self: treble.Source)

return {}
