/* CoreAudio output for the player.
 *
 * An AudioUnit render callback runs on a real time thread, where calling back
 * into Lua would be unsafe. So the audio goes through a ring this file owns: Lua
 * pushes frames in, the callback pulls them out, and nothing but C runs on the
 * audio thread.
 */

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>

#include <stdlib.h>
#include <string.h>

/* Asking for this instead of a device id renders without hardware. */
#define TREBLE_CORE_NO_DEVICE 0xFFFFFFFFu

/* Room for about three quarters of a second at 44.1 kHz. */
#define TREBLE_CORE_CAPACITY_FRAMES (1u << 15)

typedef struct treble_core {
	AudioUnit unit;
	unsigned int channels;
	unsigned int capacityFrames;
	short* ring;
	volatile uint32_t writeIndex; /* Frames pushed by Lua. */
	volatile uint32_t readIndex;  /* Frames pulled by the audio thread. */
	double sampleRate;
	int isRunning;
} treble_core;

void treble_core_close(void* handle);

static OSStatus treble_core_render(
	void* userData,
	AudioUnitRenderActionFlags* flags,
	const AudioTimeStamp* now,
	UInt32 bus,
	UInt32 frames,
	AudioBufferList* data)
{
	treble_core* core = userData;
	short* out = (short*)data->mBuffers[0].mData;
	uint32_t write = core->writeIndex;
	uint32_t read = core->readIndex;
	uint32_t available = write - read;
	uint32_t toCopy = frames < available ? frames : available;
	UInt32 index;

	if (out == NULL) {
		return noErr;
	}

	for (index = 0; index < toCopy; index++) {
		uint32_t slot = (read + index) % core->capacityFrames;

		memcpy(out + (size_t)index * core->channels,
			core->ring + (size_t)slot * core->channels,
			core->channels * sizeof(short));
	}

	/* A starved callback outputs silence rather than repeating old frames. */
	if (toCopy < frames) {
		memset(out + (size_t)toCopy * core->channels, 0,
			(size_t)(frames - toCopy) * core->channels * sizeof(short));
	}

	core->readIndex = read + toCopy;

	return noErr;
}

/* An AudioDeviceID to render to, or 0 for the default output device. */
void* treble_core_open(double sampleRate, unsigned int channels, unsigned int deviceId)
{
	treble_core* core = calloc(1, sizeof(treble_core));
	AudioComponentDescription description;
	AudioComponent component;
	AudioStreamBasicDescription format;
	AURenderCallbackStruct callback;
	OSStatus result;

	if (core == NULL || channels == 0) {
		free(core);
		return NULL;
	}

	core->channels = channels;
	core->capacityFrames = TREBLE_CORE_CAPACITY_FRAMES;
	core->sampleRate = sampleRate;
	core->ring = calloc((size_t)core->capacityFrames * channels, sizeof(short));

	if (core->ring == NULL) {
		free(core);
		return NULL;
	}

	description.componentType = kAudioUnitType_Output;
	/* A machine with no audio hardware falls back to the generic output unit,
	 * which runs the same callback and timing without a device behind it. */
	description.componentSubType = deviceId == TREBLE_CORE_NO_DEVICE
		? kAudioUnitSubType_GenericOutput
		: kAudioUnitSubType_DefaultOutput;
	description.componentManufacturer = kAudioUnitManufacturer_Apple;
	description.componentFlags = 0;
	description.componentFlagsMask = 0;

	component = AudioComponentFindNext(NULL, &description);
	if (component == NULL) {
		free(core->ring);
		free(core);
		return NULL;
	}

	result = AudioComponentInstanceNew(component, &core->unit);
	if (result != noErr) {
		free(core->ring);
		free(core);
		return NULL;
	}

	if (deviceId != 0 && deviceId != TREBLE_CORE_NO_DEVICE) {
		AudioDeviceID device = (AudioDeviceID)deviceId;

		AudioUnitSetProperty(core->unit, kAudioOutputUnitProperty_CurrentDevice,
			kAudioUnitScope_Global, 0, &device, sizeof(device));
	}

	memset(&format, 0, sizeof(format));
	format.mSampleRate = sampleRate;
	format.mFormatID = kAudioFormatLinearPCM;
	format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
	format.mFramesPerPacket = 1;
	format.mChannelsPerFrame = channels;
	format.mBitsPerChannel = 16;
	format.mBytesPerFrame = channels * sizeof(short);
	format.mBytesPerPacket = channels * sizeof(short);

	result = AudioUnitSetProperty(core->unit, kAudioUnitProperty_StreamFormat,
		kAudioUnitScope_Input, 0, &format, sizeof(format));
	if (result != noErr) {
		treble_core_close(core);
		return NULL;
	}

	callback.inputProc = treble_core_render;
	callback.inputProcRefCon = core;

	result = AudioUnitSetProperty(core->unit, kAudioUnitProperty_SetRenderCallback,
		kAudioUnitScope_Input, 0, &callback, sizeof(callback));
	if (result != noErr) {
		treble_core_close(core);
		return NULL;
	}

	if (AudioUnitInitialize(core->unit) != noErr) {
		treble_core_close(core);
		return NULL;
	}

	return core;
}

void treble_core_start(void* handle)
{
	treble_core* core = handle;
	if (core == NULL || core->isRunning) {
		return;
	}

	if (AudioOutputUnitStart(core->unit) == noErr) {
		core->isRunning = 1;
	}
}

void treble_core_stop(void* handle)
{
	treble_core* core = handle;
	if (core == NULL || !core->isRunning) {
		return;
	}

	AudioOutputUnitStop(core->unit);
	core->isRunning = 0;
}

/* Frames the ring can take right now. */
unsigned int treble_core_avail(const void* handle)
{
	const treble_core* core = handle;
	uint32_t queued;

	if (core == NULL) {
		return 0;
	}

	queued = core->writeIndex - core->readIndex;

	return core->capacityFrames - queued;
}

/* Frames pushed in but not rendered yet, which is the playback position's clock. */
unsigned int treble_core_delay(const void* handle)
{
	const treble_core* core = handle;

	if (core == NULL) {
		return 0;
	}

	return (unsigned int)(core->writeIndex - core->readIndex);
}

unsigned int treble_core_write(void* handle, const short* samples, unsigned int frames)
{
	treble_core* core = handle;
	uint32_t write;
	uint32_t available;
	unsigned int index;

	if (core == NULL) {
		return 0;
	}

	write = core->writeIndex;
	available = core->capacityFrames - (write - core->readIndex);
	if (frames > available) {
		frames = available;
	}

	for (index = 0; index < frames; index++) {
		uint32_t slot = (write + index) % core->capacityFrames;

		memcpy(core->ring + (size_t)slot * core->channels,
			samples + (size_t)index * core->channels,
			core->channels * sizeof(short));
	}

	core->writeIndex = write + frames;

	return frames;
}

/* Throws away what is queued, which is what a seek or a skip needs. */
void treble_core_flush(void* handle)
{
	treble_core* core = handle;
	if (core == NULL) {
		return;
	}

	core->readIndex = core->writeIndex;
}

void treble_core_close(void* handle)
{
	treble_core* core = handle;
	if (core == NULL) {
		return;
	}

	if (core->unit != NULL) {
		AudioOutputUnitStop(core->unit);
		AudioUnitUninitialize(core->unit);
		AudioComponentInstanceDispose(core->unit);
		core->unit = NULL;
	}

	free(core->ring);
	free(core);
}
