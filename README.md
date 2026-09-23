# treble

A cross platform playback audio library for LuaJIT.

## Features

- Audio Playback
- Metadata Parsing

## Backends

| Backend   | Windows | Linux | macOS |
| --------- | ------- | ----- | ----- |
| WASAPI    | ✅      | ❌    | ❌    |
| ALSA      | ❌      | ✅    | ❌    |
| CoreAudio | ❌      | ❌    | ✅    |

## Formats

| Format   | Decoder     | Tags                      |
| -------- | ----------- | ------------------------- |
| WAV      | built in    | `INFO` chunks             |
| FLAC     | dr_flac     | Vorbis comments, pictures |
| MP3      | dr_mp3      | ID3v2, ID3v1, pictures    |
| Ogg Opus | libopusfile | Vorbis comments, pictures |

A picture comes back as its MIME type and its raw bytes, to hand to an image
library.

## Installation

Use this package with the [lde](https://lde.sh/) package manager.

```bash
lde add treble
```

## Usage

Play a sound with one call:

```lua
local treble = require("treble")

treble.play("jump.wav", 0.5)
```

For music, drive a player from your frame loop:

```lua
local treble = require("treble")

local player = treble.Player.new()
player:enqueue("album/01.flac")
player:enqueue("album/02.flac")
player:play()

player:update() -- once a frame, which is what feeds the device
print(player:position(), player:duration())
player:seek(30)
player:next()
player:stop()
```

Queued tracks run back to back without a gap, position and seeking come from the
device clock, and `player.onTrackEnd` and `player.onError` report what happened.

## Building

The compressed formats are vendored C sources, so `build.lua` fetches them and
compiles them when the package is installed. lde needs a C compiler on the PATH.

See [ATTRIBUTIONS.md](./ATTRIBUTIONS.md) for what is vendored.
