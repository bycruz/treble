-- Windows output through WASAPI, in shared mode.
--
-- Shared mode normally insists on the mix format of the endpoint. Asking for
-- AUTOCONVERTPCM instead lets the client be fed this library's own format - signed
-- 16 bit at whatever rate and channel count the track uses - and Windows converts
-- it, which is the same arrangement the ALSA backend gets from soft resampling.
local ffi = require("ffi")

local CLSCTX_ALL = 23
local COINIT_MULTITHREADED = 0

local AUDCLNT_SHAREMODE_SHARED = 0
local AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM = 0x80000000
local AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY = 0x08000000

-- The stream will hold a tenth of a second, in 100 nanosecond units.
local BUFFER_DURATION = 1000000

local WAVE_FORMAT_PCM = 1

-- eRender, eConsole
local DEVICE_FLOW = 0
local DEVICE_ROLE = 0

ffi.cdef([[
	typedef int32_t HRESULT;
	typedef uint32_t ULONG;
	typedef uint32_t DWORD;
	typedef uint32_t UINT32;
	typedef int64_t REFERENCE_TIME;
	typedef void* HANDLE;
	typedef void* LPVOID;

	typedef struct {
		uint32_t Data1;
		uint16_t Data2;
		uint16_t Data3;
		uint8_t Data4[8];
	} GUID;
	typedef GUID IID;
	typedef GUID CLSID;

	typedef struct {
		uint16_t wFormatTag;
		uint16_t nChannels;
		uint32_t nSamplesPerSec;
		uint32_t nAvgBytesPerSec;
		uint16_t nBlockAlign;
		uint16_t wBitsPerSample;
		uint16_t cbSize;
	} WAVEFORMATEX;

	typedef struct IMMDeviceEnumerator IMMDeviceEnumerator;
	typedef struct IMMDevice IMMDevice;
	typedef struct IAudioClient IAudioClient;
	typedef struct IAudioRenderClient IAudioRenderClient;

	struct IMMDeviceEnumerator {
		struct {
			HRESULT (*QueryInterface)(IMMDeviceEnumerator*, const IID*, void**);
			ULONG (*AddRef)(IMMDeviceEnumerator*);
			ULONG (*Release)(IMMDeviceEnumerator*);
			HRESULT (*EnumAudioEndpoints)(IMMDeviceEnumerator*, int, DWORD, void**);
			HRESULT (*GetDefaultAudioEndpoint)(IMMDeviceEnumerator*, int, int, IMMDevice**);
			HRESULT (*GetDevice)(IMMDeviceEnumerator*, const wchar_t*, IMMDevice**);
			HRESULT (*RegisterEndpointNotificationCallback)(IMMDeviceEnumerator*, void*);
			HRESULT (*UnregisterEndpointNotificationCallback)(IMMDeviceEnumerator*, void*);
		} *lpVtbl;
	};

	struct IMMDevice {
		struct {
			HRESULT (*QueryInterface)(IMMDevice*, const IID*, void**);
			ULONG (*AddRef)(IMMDevice*);
			ULONG (*Release)(IMMDevice*);
			HRESULT (*Activate)(IMMDevice*, const IID*, DWORD, void*, void**);
			HRESULT (*OpenPropertyStore)(IMMDevice*, DWORD, void**);
			HRESULT (*GetId)(IMMDevice*, wchar_t**);
			HRESULT (*GetState)(IMMDevice*, DWORD*);
		} *lpVtbl;
	};

	struct IAudioClient {
		struct {
			HRESULT (*QueryInterface)(IAudioClient*, const IID*, void**);
			ULONG (*AddRef)(IAudioClient*);
			ULONG (*Release)(IAudioClient*);
			HRESULT (*Initialize)(IAudioClient*, int, DWORD, REFERENCE_TIME, REFERENCE_TIME,
				const WAVEFORMATEX*, const GUID*);
			HRESULT (*GetBufferSize)(IAudioClient*, UINT32*);
			HRESULT (*GetStreamLatency)(IAudioClient*, REFERENCE_TIME*);
			HRESULT (*GetCurrentPadding)(IAudioClient*, UINT32*);
			HRESULT (*IsFormatSupported)(IAudioClient*, int, const WAVEFORMATEX*, WAVEFORMATEX**);
			HRESULT (*GetMixFormat)(IAudioClient*, WAVEFORMATEX**);
			HRESULT (*GetDevicePeriod)(IAudioClient*, REFERENCE_TIME*, REFERENCE_TIME*);
			HRESULT (*Start)(IAudioClient*);
			HRESULT (*Stop)(IAudioClient*);
			HRESULT (*Reset)(IAudioClient*);
			HRESULT (*SetEventHandle)(IAudioClient*, HANDLE);
			HRESULT (*GetService)(IAudioClient*, const IID*, void**);
		} *lpVtbl;
	};

	struct IAudioRenderClient {
		struct {
			HRESULT (*QueryInterface)(IAudioRenderClient*, const IID*, void**);
			ULONG (*AddRef)(IAudioRenderClient*);
			ULONG (*Release)(IAudioRenderClient*);
			HRESULT (*GetBuffer)(IAudioRenderClient*, UINT32, uint8_t**);
			HRESULT (*ReleaseBuffer)(IAudioRenderClient*, UINT32, DWORD);
		} *lpVtbl;
	};

	HRESULT CoInitializeEx(void* reserved, DWORD coinit);
	void CoUninitialize(void);
	HRESULT CoCreateInstance(const CLSID* clsid, void* outer, DWORD clsctx, const IID* iid, void** out);
	void CoTaskMemFree(void* memory);
	void Sleep(DWORD milliseconds);
]])

--- A COM interface pointer. The vtable it points at is declared in ffi.cdef,
--- where the language server cannot see it.
---@class treble.ffi.comInterface: ffi.cdata*
---@field lpVtbl any

---@class treble.ffi.guid: ffi.cdata*
---@field Data1 number
---@field Data2 number
---@field Data3 number
---@field Data4 number[]

---@class treble.ffi.waveFormat: ffi.cdata*
---@field wFormatTag number
---@field nChannels number
---@field nSamplesPerSec number
---@field nAvgBytesPerSec number
---@field nBlockAlign number
---@field wBitsPerSample number
---@field cbSize number

local ole32 = ffi.load("ole32")
local kernel32 = ffi.load("kernel32")

---@param a number
---@param b number
---@param c number
---@param d number
---@param e number
---@param f number
---@param g number
---@param h number
---@param i number
---@param j number
---@param k number
---@return treble.ffi.guid
local function guid(a, b, c, d, e, f, g, h, i, j, k)
	local value = ffi.new("GUID")
	---@cast value treble.ffi.guid

	value.Data1 = a
	value.Data2 = b
	value.Data3 = c
	value.Data4[0] = d
	value.Data4[1] = e
	value.Data4[2] = f
	value.Data4[3] = g
	value.Data4[4] = h
	value.Data4[5] = i
	value.Data4[6] = j
	value.Data4[7] = k

	return value
end

local CLSID_MMDeviceEnumerator = guid(0xBCDE0395, 0xE52F, 0x467C, 0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E)
local IID_IMMDeviceEnumerator = guid(0xA95664D2, 0x9614, 0x4F35, 0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6)
local IID_IAudioClient = guid(0x1CB9AD4C, 0xDBFA, 0x4C32, 0xB1, 0x78, 0xC2, 0xF5, 0x68, 0xA7, 0x03, 0xB2)
local IID_IAudioRenderClient = guid(0xF294ACFC, 0x3146, 0x4483, 0xA7, 0xBF, 0xAD, 0xDC, 0xA7, 0xC2, 0x60, 0xE2)

---@class treble.raw.wasapi
---@field open fun(sampleRate: number, channels: number, device: string?): treble.OutputStream?, string?
local wasapi = {}

local isInitialised = false

---@return string? err
local function initialise()
	if isInitialised then
		return nil
	end

	local result = ole32.CoInitializeEx(nil, COINIT_MULTITHREADED)
	-- S_FALSE means this thread already had an apartment, which is fine.
	if result < 0 then
		return string.format("Failed to start COM: 0x%08X", result)
	end

	isInitialised = true

	return nil
end

---@param result number
---@return string
local function hresult(result)
	return string.format("0x%08X", result)
end

---@class treble.raw.wasapi.Stream: treble.OutputStream
---@field sampleRate number
---@field channels number
---@field private client treble.ffi.comInterface
---@field private render treble.ffi.comInterface
---@field private bufferFrames number
---@field private isPaused boolean
local Stream = {}
Stream.__index = Stream

--- Frames the endpoint can take right now.
function Stream:avail()
	local padding = ffi.new("UINT32[1]")

	if self.client.lpVtbl.GetCurrentPadding(self.client, padding) < 0 then
		return 0
	end

	return self.bufferFrames - padding[0]
end

---@param samples ffi.cdata*
---@param frames number
function Stream:write(samples, frames)
	local available = self:avail()
	if frames > available then
		frames = available
	end

	if frames == 0 then
		return 0
	end

	local target = ffi.new("uint8_t*[1]")
	if self.render.lpVtbl.GetBuffer(self.render, frames, target) < 0 then
		return 0
	end

	ffi.copy(target[0], samples, frames * self.channels * 2)

	if self.render.lpVtbl.ReleaseBuffer(self.render, frames, 0) < 0 then
		return 0
	end

	return frames
end

--- Frames written but not rendered yet, which is the playback position's clock.
function Stream:delay()
	local padding = ffi.new("UINT32[1]")

	if self.client.lpVtbl.GetCurrentPadding(self.client, padding) < 0 then
		return 0
	end

	return padding[0]
end

---@param isPaused boolean
function Stream:setPaused(isPaused)
	self.isPaused = isPaused

	if isPaused then
		self.client.lpVtbl.Stop(self.client)
	else
		self.client.lpVtbl.Start(self.client)
	end
end

--- Drops what the endpoint still holds, which is what a seek needs.
function Stream:flush()
	self.client.lpVtbl.Reset(self.client)
	self.client.lpVtbl.Start(self.client)
end

--- Waits for what is buffered to be rendered, so a track's tail is not cut off.
function Stream:drain()
	local padding = ffi.new("UINT32[1]")
	local waited = 0

	while self.client.lpVtbl.GetCurrentPadding(self.client, padding) >= 0 and padding[0] > 0 and waited < 1000 do
		kernel32.Sleep(5)
		waited = waited + 5
	end
end

function Stream:close()
	if self.client ~= nil then
		self.client.lpVtbl.Stop(self.client)
	end

	if self.render ~= nil then
		self.render.lpVtbl.Release(self.render)
		self.render = nil
	end

	if self.client ~= nil then
		self.client.lpVtbl.Release(self.client)
		self.client = nil
	end
end

--- Selects the endpoint to render to. An id from IMMDevice::GetId picks that
--- device, anything else takes the default.
---@param enumerator treble.ffi.comInterface
---@param device string?
---@return treble.ffi.comInterface? endpoint
---@return string? err
local function openEndpoint(enumerator, device)
	local target = ffi.new("IMMDevice*[1]")

	if device == nil or device == "" then
		local result = enumerator.lpVtbl.GetDefaultAudioEndpoint(enumerator, DEVICE_FLOW, DEVICE_ROLE, target)
		if result < 0 then
			return nil, "Failed to find a default audio device: " .. hresult(result)
		end

		return target[0]
	end

	local wide = ffi.new("wchar_t[?]", #device + 1)
	for index = 1, #device do
		wide[index - 1] = device:byte(index)
	end

	local result = enumerator.lpVtbl.GetDevice(enumerator, wide, target)
	if result < 0 then
		return nil, "Failed to open audio device: " .. hresult(result)
	end

	return target[0]
end

---@param sampleRate number
---@param channels number
---@param device string?
---@return treble.raw.wasapi.Stream? stream
---@return string? err
function wasapi.open(sampleRate, channels, device)
	local err = initialise()
	if err ~= nil then
		return nil, err
	end

	---@type treble.ffi.comInterface[]
	local enumerator = ffi.new("IMMDeviceEnumerator*[1]")
	local result = ole32.CoCreateInstance(
		CLSID_MMDeviceEnumerator, nil, CLSCTX_ALL, IID_IMMDeviceEnumerator, ffi.cast("void**", enumerator))
	if result < 0 then
		return nil, "Failed to reach the audio devices: " .. hresult(result)
	end

	local endpoint, endpointErr = openEndpoint(enumerator[0], device)
	enumerator[0].lpVtbl.Release(enumerator[0])

	if endpoint == nil then
		return nil, endpointErr
	end

	---@type treble.ffi.comInterface[]
	local client = ffi.new("IAudioClient*[1]")
	result = endpoint.lpVtbl.Activate(endpoint, IID_IAudioClient, CLSCTX_ALL, nil, ffi.cast("void**", client))
	endpoint.lpVtbl.Release(endpoint)

	if result < 0 then
		return nil, "Failed to open the audio client: " .. hresult(result)
	end

	local format = ffi.new("WAVEFORMATEX")
	---@cast format treble.ffi.waveFormat

	format.wFormatTag = WAVE_FORMAT_PCM
	format.nChannels = channels
	format.nSamplesPerSec = sampleRate
	format.wBitsPerSample = 16
	format.nBlockAlign = channels * 2
	format.nAvgBytesPerSec = sampleRate * format.nBlockAlign
	format.cbSize = 0

	result = client[0].lpVtbl.Initialize(
		client[0],
		AUDCLNT_SHAREMODE_SHARED,
		AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM + AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
		BUFFER_DURATION,
		0,
		format,
		nil
	)
	if result < 0 then
		client[0].lpVtbl.Release(client[0])
		return nil, "Failed to configure the audio client: " .. hresult(result)
	end

	---@type treble.ffi.comInterface[]
	local render = ffi.new("IAudioRenderClient*[1]")
	result = client[0].lpVtbl.GetService(client[0], IID_IAudioRenderClient, ffi.cast("void**", render))
	if result < 0 then
		client[0].lpVtbl.Release(client[0])
		return nil, "Failed to reach the audio renderer: " .. hresult(result)
	end

	local size = ffi.new("UINT32[1]")
	result = client[0].lpVtbl.GetBufferSize(client[0], size)
	if result < 0 then
		render[0].lpVtbl.Release(render[0])
		client[0].lpVtbl.Release(client[0])
		return nil, "Failed to size the audio buffer: " .. hresult(result)
	end

	client[0].lpVtbl.Start(client[0])

	---@type treble.raw.wasapi.Stream
	local stream = setmetatable({
		client = client[0],
		render = render[0],
		bufferFrames = size[0],
		sampleRate = sampleRate,
		channels = channels,
		isPaused = false,
	}, Stream)

	return stream
end

return wasapi
