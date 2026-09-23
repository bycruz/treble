local test = require("lde-test")

local isSupported = jit.os == "Linux" or jit.os == "Windows" or jit.os == "OSX"

test.skipIf(not isSupported)("the entry point exposes the player and the formats", function()
	local treble = require("treble")
	test.truthy(treble.Player)
	test.truthy(treble.play)
	test.truthy(treble.update)
	test.truthy(treble.Audio.fromPath)
end)
