/* The C surface treble keeps for MP3 decoding.
 *
 * dr_mp3 stores its decoder state in a struct whose size only its own header
 * knows, and it exposes the sample rate and channel count as struct fields
 * rather than through functions. LuaJIT cannot see either, so this shim owns the
 * struct and hands Lua an opaque handle, plus the two accessors dr_mp3 lacks.
 */

#define DR_MP3_IMPLEMENTATION
#include "dr_mp3.h"

#include <stdlib.h>
#include <string.h>

typedef struct treble_mp3 {
	drmp3 decoder;
	drmp3_uint64 cursor;
	/* Tags are copied out of the decoder: the pointers dr_mp3 hands the callback
	 * do not outlive the open call. */
	unsigned char* tagData;
	size_t tagSize;
	unsigned int tagKind;
} treble_mp3;

/* 0 for none, 1 for ID3v1, 2 for ID3v2. */
static void treble_mp3_capture(treble_mp3* handle, const drmp3_metadata* metadata)
{
	unsigned int kind = metadata->type == DRMP3_METADATA_TYPE_ID3V2 ? 2 : 1;

	/* An ID3v2 tag wins over the fixed size v1 footer. */
	if (handle->tagData != NULL && kind == 1) {
		return;
	}

	unsigned char* copy = malloc(metadata->rawDataSize);
	if (copy == NULL) {
		return;
	}

	memcpy(copy, metadata->pRawData, metadata->rawDataSize);
	free(handle->tagData);

	handle->tagData = copy;
	handle->tagSize = metadata->rawDataSize;
	handle->tagKind = kind;
}

static void treble_mp3_on_meta(void* userData, const drmp3_metadata* metadata)
{
	treble_mp3_capture((treble_mp3*)userData, metadata);
}

void* treble_mp3_open_file(const char* path)
{
	treble_mp3* handle = calloc(1, sizeof(treble_mp3));
	if (handle == NULL) {
		return NULL;
	}

	if (drmp3_init_file_with_metadata(&handle->decoder, path, treble_mp3_on_meta, handle, NULL) == DRMP3_FALSE) {
		free(handle);
		return NULL;
	}

	return handle;
}

/* The data pointer must stay valid and unchanged for the life of the handle. */
void* treble_mp3_open_memory(const void* data, size_t size)
{
	treble_mp3* handle = calloc(1, sizeof(treble_mp3));
	if (handle == NULL) {
		return NULL;
	}

	if (drmp3_init_memory_with_metadata(&handle->decoder, data, size, treble_mp3_on_meta, handle, NULL) == DRMP3_FALSE) {
		free(handle);
		return NULL;
	}

	return handle;
}

unsigned int treble_mp3_channels(const void* handle)
{
	return ((const treble_mp3*)handle)->decoder.channels;
}

unsigned int treble_mp3_sample_rate(const void* handle)
{
	return ((const treble_mp3*)handle)->decoder.sampleRate;
}

/* The frame count when the file states it, and 0 when it does not.
 *
 * drmp3_get_pcm_frame_count falls back to walking every frame of a file whose
 * Xing/Info tag is missing, which is fine on a local disk and unacceptable on a
 * network mount. A source that cannot state its length reports 0 instead, and the
 * player treats the end of the data as the end of the track.
 */
unsigned long long treble_mp3_frame_count(const void* handle)
{
	const drmp3* decoder = &((const treble_mp3*)handle)->decoder;

	if (decoder->totalPCMFrameCount == DRMP3_UINT64_MAX) {
		return 0;
	}

	return drmp3_get_pcm_frame_count((drmp3*)decoder);
}

unsigned long long treble_mp3_cursor(const void* handle)
{
	return ((const treble_mp3*)handle)->cursor;
}

/* Returns the frames written to out, which is frames * channels samples wide. */
unsigned long long treble_mp3_read_s16(void* handle, short* out, unsigned long long frames)
{
	treble_mp3* mp3 = handle;
	drmp3_uint64 read = drmp3_read_pcm_frames_s16(&mp3->decoder, frames, out);
	mp3->cursor += read;

	return read;
}

unsigned int treble_mp3_seek(void* handle, unsigned long long frame)
{
	treble_mp3* mp3 = handle;
	if (drmp3_seek_to_pcm_frame(&mp3->decoder, frame) == DRMP3_FALSE) {
		return 0;
	}

	mp3->cursor = frame;

	return 1;
}

/* 0 for none, 1 for ID3v1, 2 for ID3v2. */
unsigned int treble_mp3_tag_kind(const void* handle)
{
	return ((const treble_mp3*)handle)->tagKind;
}

const unsigned char* treble_mp3_tag_data(const void* handle)
{
	return ((const treble_mp3*)handle)->tagData;
}

unsigned long long treble_mp3_tag_size(const void* handle)
{
	return ((const treble_mp3*)handle)->tagSize;
}

void treble_mp3_close(void* handle)
{
	treble_mp3* mp3 = handle;
	if (mp3 == NULL) {
		return;
	}

	drmp3_uninit(&mp3->decoder);
	free(mp3->tagData);
	free(mp3);
}
