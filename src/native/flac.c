/* The C surface treble keeps for FLAC decoding.
 *
 * dr_flac allocates its own decoder, but the fields a caller needs - the channel
 * count, the sample rate and the length - live in a struct only its header knows,
 * so they are read here and handed out as functions.
 */

#define DR_FLAC_IMPLEMENTATION
#define DR_FLAC_NO_WRITE
#include "dr_flac.h"

#include <stdlib.h>
#include <string.h>

typedef struct treble_flac {
	drflac* decoder;
	/* Tags are copied out of the decoder: the pointers the metadata callback hands
	 * over are only valid while it runs. */
	unsigned char* comments;   /* Repeated: 4 byte length, then that many bytes. */
	unsigned int commentCount;
	size_t commentSize;
	char* vendor;
	char* pictureMime;
	char* pictureDescription;
	unsigned char* pictureData;
	size_t pictureSize;
} treble_flac;

static char* treble_flac_copyString(const char* value, unsigned int length)
{
	char* copy = malloc(length + 1);
	if (copy == NULL) {
		return NULL;
	}

	if (value != NULL) {
		memcpy(copy, value, length);
	}

	copy[length] = 0;

	return copy;
}

static void treble_flac_on_meta(void* userData, drflac_metadata* metadata)
{
	treble_flac* handle = userData;

	if (metadata->type == DRFLAC_METADATA_BLOCK_TYPE_VORBIS_COMMENT) {
		const void* comments = metadata->data.vorbis_comment.pComments;
		unsigned int count = metadata->data.vorbis_comment.commentCount;

		free(handle->vendor);
		handle->vendor = treble_flac_copyString(
			metadata->data.vorbis_comment.vendor, metadata->data.vorbis_comment.vendorLength);

		free(handle->comments);
		handle->comments = NULL;
		handle->commentCount = 0;
		handle->commentSize = 0;

		drflac_vorbis_comment_iterator iterator;
		drflac_uint32 length;
		const char* comment;

		drflac_init_vorbis_comment_iterator(&iterator, count, comments);
		while ((comment = drflac_next_vorbis_comment(&iterator, &length)) != NULL) {
			unsigned char* grown = realloc(handle->comments, handle->commentSize + 4 + length);
			if (grown == NULL) {
				return;
			}

			handle->comments = grown;
			handle->comments[handle->commentSize + 0] = (unsigned char)(length & 0xFF);
			handle->comments[handle->commentSize + 1] = (unsigned char)((length >> 8) & 0xFF);
			handle->comments[handle->commentSize + 2] = (unsigned char)((length >> 16) & 0xFF);
			handle->comments[handle->commentSize + 3] = (unsigned char)((length >> 24) & 0xFF);
			memcpy(handle->comments + handle->commentSize + 4, comment, length);

			handle->commentSize += 4 + length;
			handle->commentCount += 1;
		}
	} else if (metadata->type == DRFLAC_METADATA_BLOCK_TYPE_PICTURE) {
		free(handle->pictureMime);
		free(handle->pictureDescription);
		free(handle->pictureData);

		handle->pictureMime = treble_flac_copyString(
			metadata->data.picture.mime, metadata->data.picture.mimeLength);
		handle->pictureDescription = treble_flac_copyString(
			metadata->data.picture.description, metadata->data.picture.descriptionLength);

		handle->pictureSize = metadata->data.picture.pictureDataSize;
		handle->pictureData = malloc(handle->pictureSize);
		if (handle->pictureData != NULL) {
			memcpy(handle->pictureData, metadata->data.picture.pPictureData, handle->pictureSize);
		}
	}
}

/* Opens with the metadata callback attached, so tags are captured on the way in. */
static treble_flac* treble_flac_open(int useFile, const char* path, const void* data, size_t size)
{
	treble_flac* handle = calloc(1, sizeof(treble_flac));
	if (handle == NULL) {
		return NULL;
	}

	handle->decoder = useFile
		? drflac_open_file_with_metadata(path, treble_flac_on_meta, handle, NULL)
		: drflac_open_memory_with_metadata(data, size, treble_flac_on_meta, handle, NULL);

	if (handle->decoder == NULL) {
		free(handle->comments);
		free(handle->vendor);
		free(handle);
		return NULL;
	}

	return handle;
}

void* treble_flac_open_file(const char* path)
{
	return treble_flac_open(1, path, NULL, 0);
}

/* The data pointer must stay valid for the life of the handle. */
void* treble_flac_open_memory(const void* data, size_t size)
{
	return treble_flac_open(0, NULL, data, size);
}

unsigned int treble_flac_channels(const void* handle)
{
	return ((const treble_flac*)handle)->decoder->channels;
}

unsigned int treble_flac_sample_rate(const void* handle)
{
	return ((const treble_flac*)handle)->decoder->sampleRate;
}

unsigned long long treble_flac_frame_count(const void* handle)
{
	return ((const treble_flac*)handle)->decoder->totalPCMFrameCount;
}

unsigned long long treble_flac_read_s16(void* handle, short* out, unsigned long long frames)
{
	return drflac_read_pcm_frames_s16(((treble_flac*)handle)->decoder, frames, out);
}

unsigned int treble_flac_seek(void* handle, unsigned long long frame)
{
	return drflac_seek_to_pcm_frame(((treble_flac*)handle)->decoder, frame) == DRFLAC_TRUE;
}

/* Repeated: a four byte little endian length, then that many bytes of comment. */
const unsigned char* treble_flac_comments(const void* handle)
{
	return ((const treble_flac*)handle)->comments;
}

unsigned int treble_flac_comment_count(const void* handle)
{
	return ((const treble_flac*)handle)->commentCount;
}

unsigned long long treble_flac_comment_size(const void* handle)
{
	return ((const treble_flac*)handle)->commentSize;
}

const char* treble_flac_vendor(const void* handle)
{
	return ((const treble_flac*)handle)->vendor;
}

const char* treble_flac_picture_mime(const void* handle)
{
	return ((const treble_flac*)handle)->pictureMime;
}

const char* treble_flac_picture_description(const void* handle)
{
	return ((const treble_flac*)handle)->pictureDescription;
}

const unsigned char* treble_flac_picture_data(const void* handle)
{
	return ((const treble_flac*)handle)->pictureData;
}

unsigned long long treble_flac_picture_size(const void* handle)
{
	return ((const treble_flac*)handle)->pictureSize;
}

void treble_flac_close(void* handle)
{
	treble_flac* flac = handle;
	if (flac == NULL) {
		return;
	}

	drflac_close(flac->decoder);
	free(flac->comments);
	free(flac->vendor);
	free(flac->pictureMime);
	free(flac->pictureDescription);
	free(flac->pictureData);
	free(flac);
}
