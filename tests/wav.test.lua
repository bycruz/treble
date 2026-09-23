local test = require("lde-test")
local buffer = require("string.buffer")
local ffi = require("ffi")
local fixture = require("tests.fixtures.wav")
local Wav = require("treble.formats.wav")

local Samples = ffi.typeof("int16_t[?]")
local Int16 = ffi.typeof("int16_t[1]")
local Float = ffi.typeof("float[1]")

-- Sources read from caller memory, so the buffers have to outlive the tests.
local held = {}

---@param content string
---@return treble.formats.WavSource
local function open(content)
	local content_ = buffer.new()
	content_:put(content)
	held[#held + 1] = content_

	return assert(Wav.fromMemory(ffi.cast("const char*", content_:ref()), #content_))
end

---@param source treble.Source
---@param frames number
---@return ffi.cdata* samples
---@return number frames
local function read(source, frames)
	local samples = Samples(frames * source.channels)
	local total = 0

	while total < frames do
		local got = source:read(samples + total * source.channels, frames - total)
		if got == 0 then
			break
		end
		total = total + got
	end

	return samples, total
end

---@param value number
local function i16(value)
	return ffi.string(Int16(value), 2)
end

---@param value number
local function f32(value)
	return ffi.string(Float(value), 4)
end

test.it("reads the format and the frames from a PCM file", function()
	local source = open(fixture.build({ channels = 2, sampleRate = 44100, frames = 100 }))

	test.equal(source.channels, 2)
	test.equal(source.sampleRate, 44100)
	test.equal(source.frameCount, 100)
end)

test.it("hands back 16 bit samples unchanged", function()
	local bytes = i16(1) .. i16(-1) .. i16(32767) .. i16(-32768)
	local source = open(fixture.build({ frames = 4, sampleBytes = bytes }))
	local samples, frames = read(source, 4)

	test.equal(frames, 4)
	test.equal(samples[0], 1)
	test.equal(samples[1], -1)
	test.equal(samples[2], 32767)
	test.equal(samples[3], -32768)
end)

test.it("scales unsigned 8 bit samples", function()
	local source = open(fixture.build({ bitsPerSample = 8, frames = 3, sampleBytes = string.char(0, 128, 255) }))
	local samples = read(source, 3)

	test.equal(samples[0], -32768)
	test.equal(samples[1], 0)
	test.equal(samples[2], 32512)
end)

test.it("scales 24 bit samples", function()
	local bytes = string.char(0x00, 0x00, 0x80) .. string.char(0x00, 0x00, 0x00) .. string.char(0xFF, 0xFF, 0x7F)
	local source = open(fixture.build({ bitsPerSample = 24, frames = 3, sampleBytes = bytes }))
	local samples = read(source, 3)

	test.equal(samples[0], -32768)
	test.equal(samples[1], 0)
	test.equal(samples[2], 32767)
end)

test.it("scales 32 bit samples", function()
	local bytes = string.char(0xFF, 0xFF, 0xFF, 0x7F) .. string.char(0x00, 0x00, 0x00, 0x80)
	local source = open(fixture.build({ bitsPerSample = 32, frames = 2, sampleBytes = bytes }))
	local samples = read(source, 2)

	test.equal(samples[0], 32767)
	test.equal(samples[1], -32768)
end)

test.it("scales float samples and clamps them", function()
	local bytes = f32(0) .. f32(0.5) .. f32(1) .. f32(-1) .. f32(4)
	local source = open(fixture.build({ bitsPerSample = 32, audioFormat = 3, frames = 5, sampleBytes = bytes }))
	local samples = read(source, 5)

	test.equal(samples[0], 0)
	test.equal(samples[1], 16383)
	test.equal(samples[2], 32767)
	test.equal(samples[3], -32767)
	test.equal(samples[4], 32767, "values past full scale clamp")
end)

test.it("accepts an extensible header", function()
	local source = open(fixture.build({ audioFormat = 0xFFFE, frames = 8, sampleBytes = string.rep("\1\0", 8) }))
	local samples = read(source, 8)

	test.equal(source.frameCount, 8, "the extensible header still names PCM")
	test.equal(samples[0], 1)
end)

test.it("seeks to a frame and reads from there", function()
	local parts = {}
	for i = 0, 199 do
		parts[#parts + 1] = i16(i)
	end

	local source = open(fixture.build({ channels = 2, frames = 100, sampleBytes = table.concat(parts) }))
	local whole = read(source, 100)

	test.truthy(source:seek(50), "seek reports success")
	local slice = read(source, 10)
	test.equal(slice[0], whole[50 * 2], "the first sample after the seek")
	test.equal(slice[1], whole[50 * 2 + 1])
end)

test.it("stops at the end of the data", function()
	local source = open(fixture.build({ frames = 4 }))

	local samples = Samples(8 * source.channels)
	test.equal(source:read(samples, 8), 4, "a read past the end returns what is left")
	test.equal(source:read(samples, 8), 0, "and then nothing")
end)

test.it("clamps a data chunk that claims more than the file holds", function()
	local source = open(fixture.build({ frames = 4, sampleBytes = string.rep("\0", 8), dataSize = 4096 }))

	test.equal(source.frameCount, 4)
end)

test.it("skips chunks that come before the data chunk", function()
	local source = open(fixture.build({ frames = 4, extraChunk = { id = "LIST", size = 4 } }))

	test.equal(source.frameCount, 4)
end)

test.it("reports what it cannot decode", function()
	local source, err = Wav.fromMemory(ffi.cast("const char*", "not a wav file, not even close"), 29)
	test.falsy(source)
	test.truthy(err) ---@cast err -nil
	test.includes(err, "Unsupported audio format")

	local truncated, truncatedErr = Wav.fromMemory(ffi.cast("const char*", "RIFF"), 4)
	test.falsy(truncated)
	test.truthy(truncatedErr) ---@cast truncatedErr -nil
	test.includes(truncatedErr, "Truncated WAV file")
end)

test.it("reports a file with no data chunk", function()
	local content = fixture.build({ frames = 4 })
	local header = string.sub(content, 1, #content - 8 - 8)
	local source, err = Wav.fromMemory(ffi.cast("const char*", header), #header)

	test.falsy(source)
	test.truthy(err) ---@cast err -nil
	test.includes(err, "Data chunk not found")
end)

test.it("reports an encoding it does not handle", function()
	local content = fixture.build({ audioFormat = 2, frames = 4 })
	local source, err = Wav.fromMemory(ffi.cast("const char*", content), #content)

	test.falsy(source)
	test.truthy(err) ---@cast err -nil
	test.includes(err, "Unsupported WAV encoding")
end)

test.it("recognises RIFF content", function()
	test.truthy(Wav.isValid(fixture.build()))
	test.falsy(Wav.isValid("this is not audio, not even close"))
	test.falsy(Wav.isValid("RIFF" .. string.rep("\0", 8) .. "WAVE"))
end)

test.it("reads a file from disk", function()
	local content = fixture.build({ channels = 2, sampleRate = 22050, frames = 32, sampleBytes = string.rep(i16(7), 64) })
	local path = "target/treble-wav-fixture.wav"

	local file = assert(io.open(path, "wb"))
	file:write(content)
	file:close()

	local source = assert(Wav.fromPath(path))
	test.equal(source.channels, 2)
	test.equal(source.sampleRate, 22050)

	local samples = read(source, 32)
	test.equal(samples[0], 7)

	-- a file backed source reads on demand, so a seek has to reach the data again
	test.truthy(source:seek(28))
	local slice = read(source, 4)
	test.equal(slice[0], 7)
	test.equal(source:read(Samples(4), 4), 0, "the file ran out")

	source:close()
	os.remove(path)
end)

test.it("reports a file it cannot open", function()
	local source, err = Wav.fromPath("tests/fixtures/no-such-file.wav")
	test.falsy(source)
	test.truthy(err) ---@cast err -nil
	test.includes(err, "Failed to open audio file")
end)
