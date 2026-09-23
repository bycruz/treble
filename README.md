# treble

A cross-platform audio library for LuaJIT, written from scratch. It decodes audio
files into sample data and plays them through the OS mixer.

## Backends

| Backend    | Windows | Linux | macOS |
| ---------- | ------- | ----- | ----- |
| WASAPI     | ✅      | ❌    | ❌    |
| ALSA       | ❌      | ✅    | ❌    |
| CoreAudio  | ❌      | ❌    | ✅    |

Each backend opens the output at the track's own rate and channel count and lets
the platform convert: ALSA soft resampling, WASAPI `AUTOCONVERTPCM`, and CoreAudio
an AudioUnit with that stream format.

WASAPI runs in shared mode with `AUTOCONVERTPCM`, so a track at any rate or channel
count plays without this library resampling it, which is the same arrangement ALSA
gets from soft resampling.

## Installation

Use this package with the [lde](https://lde.sh/) package manager.

```bash
lde add --git https://github.com/bycruz/treble
```

## Usage

Play a short sound with one call:

```lua
local treble = require("treble")

treble.play("jump.wav", 0.5)
```

That is shorthand for a player: it queues the file, starts it, and hands the audio to
the device, so the sound needs no frame loop. It blocks only while the device is full,
so call `treble.update()` once a frame to let go of the device as soon as a sound has
finished.

For music, drive a player from your frame loop:

```lua
local treble = require("treble")

local player = treble.Player.new()
player:enqueue("first.mp3")
player:enqueue("second.opus")
player.onTrackEnd = function()
	-- the next queued track is already playing
end

player:play()
player:setVolume(0.8)

player:update()                            -- once a frame
print(player:position(), player:duration())

player:pause()
player:seek(30)
player:stop()
```

A player holds one device stream open for as long as it has something to play, so
queued tracks run back to back, and the position comes from the device clock rather
than a timer of our own. Each player opens its own stream and the OS mixer blends
them, so there is no mixing inside treble.

## Formats

| Format    | Status | Decoder         |
| --------- | ------ | --------------- |
| WAV (PCM) | ✅     | this repository |
| FLAC      | ✅     | dr_flac         |
| MP3       | ✅     | dr_mp3          |
| Ogg Opus  | ✅     | libopusfile     |

Tags come back normalised, with any picture as its raw bytes and MIME type so an
image library can decode it:

```lua
local probe = assert(treble.Audio.probe("song.mp3"))

probe.format, probe.duration, probe.sampleRate   -- "MP3", 213.4, 44100
probe.tags.title, probe.tags.artist              -- "Title", "Artist"
probe.tags.picture.mime, probe.tags.picture.data -- "image/jpeg", <bytes>
```

`Audio.probe` reads one header and no audio, so a library scan stays cheap.
Every format reports the same fields: WAV INFO chunks, ID3v2 (with ID3v1 as a
fallback), FLAC Vorbis comments and pictures, and Opus Vorbis comments.

Nothing is scanned to show a length: WAV reads its data chunk header, FLAC its
stream info, Opus the end of its last page, and MP3 only what its Xing tag states.
An MP3 without that tag reports a length of 0, which means "unknown", rather than
walking the whole file — a file is only read as it plays, so a slow mount costs no
more than the audio itself.

`treble.Audio` decodes the contents of a file into the sample data the backends
read. It folds in what used to be the separate `apl` (audio parsing library)
package.

Each format also exposes a source, which hands out frames on demand instead of
holding a whole track in memory:

```lua
local mp3 = require("treble.formats.mp3")

local source = assert(mp3.fromPath("song.mp3"))
source.channels, source.sampleRate, source.frameCount -- 2, 44100, 11404800
source:seek(30 * source.sampleRate)
```

`fromPath` reads the file itself, and `fromMemory` decodes from a pointer, which
is how a caller passes data it already holds.

## Building

`build.lua` fetches pinned release tarballs of the C decoders and compiles them
into `target/treble/decoders.so`, so lde needs a C compiler on the PATH. The
extracted sources and the compiled library are cached under `target/treble-native`
and reused until the recipe changes. See [ATTRIBUTIONS.md](./ATTRIBUTIONS.md) for
what is vendored and under which license.

## Goals

- [x] Cross platform
- [x] Zero dependencies
- [x] Written from scratch
