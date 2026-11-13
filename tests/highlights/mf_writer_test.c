/*
 * Saves an MP4 through Media Foundation's sink writer the way Overwatch saves
 * a highlight: MFCreateSinkWriterFromURL on an .mp4 path, an H.264 and an AAC
 * stream, uncompressed frames and PCM in, encoder settings through ICodecAPI,
 * then Finalize. Built with LLVM-MinGW and run in Wine against an engine with
 * winemacmf; verify_mp4.swift checks the file.
 *
 * RGB frames are written top-down with a positive stride (rgb32, argb32),
 * bottom-up with the negative stride MFGetStrideForBitmapInfoHeader gives
 * (rgb32-bottomup), or bottom-up with no stride in the type, which means the
 * same on Windows (rgb32-nostride).
 *
 *   mf_writer_test <out.mp4> [rgb32|argb32|rgb32-bottomup|rgb32-nostride|nv12] [pcm16|float]
 *                  [width height fps seconds] [--hardware] [--async] [--no-codecapi] [--channels N]
 */

#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <strmif.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static const GUID null_guid;

/* From Windows' codecapi.h, whose MinGW version needs __uuidof. */
DEFINE_GUID(CODECAPI_AVEncCommonRateControlMode, 0x1c0608e9, 0x370c, 0x4710, 0x8a, 0x58, 0xcb, 0x61, 0x81, 0xc4, 0x24, 0x23);
DEFINE_GUID(CODECAPI_AVEncCommonMeanBitRate, 0xf7222374, 0x2144, 0x4815, 0xb5, 0x50, 0xa3, 0x7f, 0x8e, 0x12, 0xee, 0x52);
DEFINE_GUID(CODECAPI_AVEncCommonQualityVsSpeed, 0x98332df8, 0x03cd, 0x476b, 0x89, 0xfa, 0x3f, 0x9e, 0x44, 0x2d, 0xec, 0x9f);
DEFINE_GUID(CODECAPI_AVEncMPVDefaultBPictureCount, 0x8d390aac, 0xdc5c, 0x4200, 0xb5, 0x7f, 0x81, 0x4d, 0x04, 0xba, 0xba, 0xb2);
DEFINE_GUID(CODECAPI_AVEncMPVGOPSize, 0x95f31b26, 0x95a4, 0x41aa, 0x93, 0x03, 0x24, 0x6a, 0x7f, 0xc6, 0xee, 0xf1);
#define eAVEncCommonRateControlMode_UnconstrainedVBR 2
#define eAVEncH264VProfile_High 100

#define CHECK(expr) do { HRESULT hr_ = (expr); if (FAILED(hr_)) { \
    printf("{\"ok\": false, \"step\": \"%s\", \"hr\": \"%#lx\"}\n", #expr, (unsigned long)hr_); return 1; } } while (0)

static const BYTE bars[8][3] = {
    {235, 235, 235}, {235, 235, 16}, {16, 235, 235}, {16, 235, 16},
    {235, 16, 235}, {235, 16, 16}, {16, 16, 235}, {16, 16, 16},
};

static void pattern_rgb(UINT width, UINT frame, UINT x, UINT y, BYTE rgb[3])
{
    UINT bar = ((x + width - (frame * 8) % width) % width) * 8 / width;

    if (y < 16 && x < 32 * 16)
    {
        rgb[0] = rgb[1] = rgb[2] = ((frame >> (x / 16)) & 1) ? 235 : 16;
        return;
    }
    memcpy(rgb, bars[bar], 3);
}

static void rgb_to_yuv(const BYTE rgb[3], BYTE *y, BYTE *u, BYTE *v)
{
    double r = (rgb[0] - 16) / 219.0, g = (rgb[1] - 16) / 219.0, b = (rgb[2] - 16) / 219.0;
    double luma = 0.2126 * r + 0.7152 * g + 0.0722 * b;

    *y = (BYTE)lround(16 + 219 * luma);
    *u = (BYTE)lround(128 + 224 * (b - luma) / 1.8556);
    *v = (BYTE)lround(128 + 224 * (r - luma) / 1.5748);
}

/* Fills a frame in the layout Media Foundation expects for the format. */
static void fill_frame(BYTE *data, const char *format, UINT width, UINT height, UINT frame)
{
    UINT x, y;
    BYTE rgb[3], Y, U, V;

    if (!strcmp(format, "nv12"))
    {
        BYTE *uv = data + width * height;
        for (y = 0; y < height; ++y)
            for (x = 0; x < width; ++x)
            {
                pattern_rgb(width, frame, x, y, rgb);
                rgb_to_yuv(rgb, &Y, &U, &V);
                data[y * width + x] = Y;
                if (!(x & 1) && !(y & 1))
                {
                    uv[(y / 2) * width + x] = U;
                    uv[(y / 2) * width + x + 1] = V;
                }
            }
        return;
    }
    for (y = 0; y < height; ++y)
    {
        /* Bottom-up frames store the last row first. */
        UINT row = !strcmp(format, "rgb32-bottomup") || !strcmp(format, "rgb32-nostride") ? height - 1 - y : y;
        for (x = 0; x < width; ++x)
        {
            BYTE *p = data + (row * width + x) * 4;
            pattern_rgb(width, frame, x, y, rgb);
            p[0] = rgb[2]; p[1] = rgb[1]; p[2] = rgb[0]; p[3] = 255;
        }
    }
}

struct callback
{
    IMFSinkWriterCallback IMFSinkWriterCallback_iface;
    HANDLE finalized;
    HRESULT status;
};

static HRESULT WINAPI callback_QueryInterface(IMFSinkWriterCallback *iface, REFIID riid, void **out)
{
    if (IsEqualIID(riid, &IID_IMFSinkWriterCallback) || IsEqualIID(riid, &IID_IUnknown))
    {
        *out = iface;
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}

static ULONG WINAPI callback_AddRef(IMFSinkWriterCallback *iface) { return 2; }
static ULONG WINAPI callback_Release(IMFSinkWriterCallback *iface) { return 1; }

static HRESULT WINAPI callback_OnFinalize(IMFSinkWriterCallback *iface, HRESULT status)
{
    struct callback *callback = CONTAINING_RECORD(iface, struct callback, IMFSinkWriterCallback_iface);
    callback->status = status;
    SetEvent(callback->finalized);
    return S_OK;
}

static HRESULT WINAPI callback_OnMarker(IMFSinkWriterCallback *iface, DWORD index, void *context) { return S_OK; }

static IMFSinkWriterCallbackVtbl callback_vtbl =
{
    callback_QueryInterface, callback_AddRef, callback_Release, callback_OnFinalize, callback_OnMarker,
};

int wmain(int argc, WCHAR **argv)
{
    const WCHAR *path;
    char video_format[32] = "rgb32", audio_format[32] = "pcm16";
    UINT width = 1920, height = 1080, fps = 60, seconds = 3, frames, rate = 48000, channels = 2, i, j;
    BOOL hardware = FALSE, async = FALSE, codecapi = TRUE;
    IMFMediaType *video_out, *video_in, *audio_out, *audio_in;
    IMFAttributes *attributes;
    IMFSinkWriter *writer;
    DWORD video, audio;
    LONG stride;
    UINT32 frame_size;
    struct callback callback = {{&callback_vtbl}};
    MF_SINK_WRITER_STATISTICS stats = {sizeof(stats)};
    DWORD start;
    int arg = 2;

    if (argc < 2) return 2;
    path = argv[1];
    if (argc > arg && argv[arg][0] != '-') WideCharToMultiByte(CP_ACP, 0, argv[arg++], -1, video_format, 32, NULL, NULL);
    if (argc > arg && argv[arg][0] != '-') WideCharToMultiByte(CP_ACP, 0, argv[arg++], -1, audio_format, 32, NULL, NULL);
    if (argc > arg + 3 && argv[arg][0] != '-')
    {
        width = _wtoi(argv[arg++]);
        height = _wtoi(argv[arg++]);
        fps = _wtoi(argv[arg++]);
        seconds = _wtoi(argv[arg++]);
    }
    for (; arg < argc; ++arg)
    {
        if (!wcscmp(argv[arg], L"--hardware")) hardware = TRUE;
        else if (!wcscmp(argv[arg], L"--async")) async = TRUE;
        else if (!wcscmp(argv[arg], L"--no-codecapi")) codecapi = FALSE;
        else if (!wcscmp(argv[arg], L"--channels") && arg + 1 < argc) channels = _wtoi(argv[++arg]);
    }
    frames = fps * seconds;

    CHECK(CoInitializeEx(NULL, COINIT_MULTITHREADED));
    CHECK(MFStartup(MF_VERSION, MFSTARTUP_FULL));

    CHECK(MFCreateAttributes(&attributes, 4));
    if (hardware) CHECK(IMFAttributes_SetUINT32(attributes, &MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE));
    CHECK(IMFAttributes_SetUINT32(attributes, &MF_SINK_WRITER_DISABLE_THROTTLING, TRUE));
    if (async)
    {
        callback.finalized = CreateEventW(NULL, TRUE, FALSE, NULL);
        CHECK(IMFAttributes_SetUnknown(attributes, &MF_SINK_WRITER_ASYNC_CALLBACK, (IUnknown *)&callback.IMFSinkWriterCallback_iface));
    }
    CHECK(MFCreateSinkWriterFromURL(path, NULL, attributes, &writer));

    CHECK(MFCreateMediaType(&video_out));
    CHECK(IMFMediaType_SetGUID(video_out, &MF_MT_MAJOR_TYPE, &MFMediaType_Video));
    CHECK(IMFMediaType_SetGUID(video_out, &MF_MT_SUBTYPE, &MFVideoFormat_H264));
    CHECK(IMFMediaType_SetUINT32(video_out, &MF_MT_AVG_BITRATE, 12000000));
    CHECK(IMFMediaType_SetUINT32(video_out, &MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive));
    CHECK(IMFMediaType_SetUINT32(video_out, &MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_High));
    CHECK(IMFMediaType_SetUINT64(video_out, &MF_MT_FRAME_SIZE, (UINT64)(width) << 32 | (height)));
    CHECK(IMFMediaType_SetUINT64(video_out, &MF_MT_FRAME_RATE, (UINT64)(fps) << 32 | (1)));
    CHECK(IMFMediaType_SetUINT64(video_out, &MF_MT_PIXEL_ASPECT_RATIO, (UINT64)(1) << 32 | (1)));
    CHECK(IMFSinkWriter_AddStream(writer, video_out, &video));

    CHECK(MFCreateMediaType(&video_in));
    CHECK(IMFMediaType_SetGUID(video_in, &MF_MT_MAJOR_TYPE, &MFMediaType_Video));
    if (!strcmp(video_format, "nv12"))
    {
        CHECK(IMFMediaType_SetGUID(video_in, &MF_MT_SUBTYPE, &MFVideoFormat_NV12));
        stride = width;
        frame_size = width * height * 3 / 2;
    }
    else
    {
        CHECK(IMFMediaType_SetGUID(video_in, &MF_MT_SUBTYPE, !strcmp(video_format, "argb32") ? &MFVideoFormat_ARGB32
                : &MFVideoFormat_RGB32));
        /* Negative for RGB, as on Windows: bottom-up rows. */
        CHECK(MFGetStrideForBitmapInfoHeader(MFVideoFormat_RGB32.Data1, width, &stride));
        if (stride >= 0) { printf("{\"ok\": false, \"step\": \"RGB stride should be negative\"}\n"); return 1; }
        if (!strcmp(video_format, "rgb32") || !strcmp(video_format, "argb32")) stride = -stride;
        frame_size = width * height * 4;
    }
    if (strcmp(video_format, "rgb32-nostride"))
        CHECK(IMFMediaType_SetUINT32(video_in, &MF_MT_DEFAULT_STRIDE, (UINT32)stride));
    CHECK(IMFMediaType_SetUINT32(video_in, &MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive));
    CHECK(IMFMediaType_SetUINT64(video_in, &MF_MT_FRAME_SIZE, (UINT64)(width) << 32 | (height)));
    CHECK(IMFMediaType_SetUINT64(video_in, &MF_MT_FRAME_RATE, (UINT64)(fps) << 32 | (1)));
    CHECK(IMFMediaType_SetUINT64(video_in, &MF_MT_PIXEL_ASPECT_RATIO, (UINT64)(1) << 32 | (1)));
    CHECK(IMFSinkWriter_SetInputMediaType(writer, video, video_in, NULL));

    if (codecapi)
    {
        /* What Overwatch's h264-win32-* settings map to. */
        ICodecAPI *api;
        VARIANT value;

        CHECK(IMFSinkWriter_GetServiceForStream(writer, video, &null_guid, &IID_ICodecAPI, (void **)&api));
        V_VT(&value) = VT_UI4;
        V_UI4(&value) = eAVEncCommonRateControlMode_UnconstrainedVBR;
        CHECK(ICodecAPI_SetValue(api, &CODECAPI_AVEncCommonRateControlMode, &value));
        V_UI4(&value) = 16000000;
        CHECK(ICodecAPI_SetValue(api, &CODECAPI_AVEncCommonMeanBitRate, &value));
        V_UI4(&value) = 50;
        CHECK(ICodecAPI_SetValue(api, &CODECAPI_AVEncCommonQualityVsSpeed, &value));
        V_UI4(&value) = 0;
        CHECK(ICodecAPI_SetValue(api, &CODECAPI_AVEncMPVDefaultBPictureCount, &value));
        V_UI4(&value) = 120;
        CHECK(ICodecAPI_SetValue(api, &CODECAPI_AVEncMPVGOPSize, &value));
        ICodecAPI_Release(api);
    }

    CHECK(MFCreateMediaType(&audio_out));
    CHECK(IMFMediaType_SetGUID(audio_out, &MF_MT_MAJOR_TYPE, &MFMediaType_Audio));
    CHECK(IMFMediaType_SetGUID(audio_out, &MF_MT_SUBTYPE, &MFAudioFormat_AAC));
    CHECK(IMFMediaType_SetUINT32(audio_out, &MF_MT_AUDIO_BITS_PER_SAMPLE, 16));
    CHECK(IMFMediaType_SetUINT32(audio_out, &MF_MT_AUDIO_SAMPLES_PER_SECOND, rate));
    CHECK(IMFMediaType_SetUINT32(audio_out, &MF_MT_AUDIO_NUM_CHANNELS, channels));
    CHECK(IMFMediaType_SetUINT32(audio_out, &MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 24000 * max(channels, 2) / 2));
    CHECK(IMFMediaType_SetUINT32(audio_out, &MF_MT_AAC_PAYLOAD_TYPE, 0));
    CHECK(IMFMediaType_SetUINT32(audio_out, &MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION, 0x29));
    CHECK(IMFSinkWriter_AddStream(writer, audio_out, &audio));

    CHECK(MFCreateMediaType(&audio_in));
    CHECK(IMFMediaType_SetGUID(audio_in, &MF_MT_MAJOR_TYPE, &MFMediaType_Audio));
    CHECK(IMFMediaType_SetGUID(audio_in, &MF_MT_SUBTYPE, !strcmp(audio_format, "float") ? &MFAudioFormat_Float
            : &MFAudioFormat_PCM));
    CHECK(IMFMediaType_SetUINT32(audio_in, &MF_MT_AUDIO_BITS_PER_SAMPLE, !strcmp(audio_format, "float") ? 32 : 16));
    CHECK(IMFMediaType_SetUINT32(audio_in, &MF_MT_AUDIO_SAMPLES_PER_SECOND, rate));
    CHECK(IMFMediaType_SetUINT32(audio_in, &MF_MT_AUDIO_NUM_CHANNELS, channels));
    CHECK(IMFSinkWriter_SetInputMediaType(writer, audio, audio_in, NULL));

    start = GetTickCount();
    CHECK(IMFSinkWriter_BeginWriting(writer));

    /* Ten milliseconds of audio per step, frames when their time comes. */
    for (i = 0, j = 0; i < frames || j < seconds * 100;)
    {
        LONGLONG video_time = i * 10000000LL / fps, audio_time = j * 100000LL;

        if (i < frames && (j >= seconds * 100 || video_time <= audio_time))
        {
            IMFMediaBuffer *buffer;
            IMFSample *sample;
            BYTE *data;

            CHECK(MFCreateAlignedMemoryBuffer(frame_size, MF_16_BYTE_ALIGNMENT, &buffer));
            CHECK(IMFMediaBuffer_Lock(buffer, &data, NULL, NULL));
            fill_frame(data, video_format, width, height, i);
            CHECK(IMFMediaBuffer_Unlock(buffer));
            CHECK(IMFMediaBuffer_SetCurrentLength(buffer, frame_size));
            CHECK(MFCreateSample(&sample));
            CHECK(IMFSample_AddBuffer(sample, buffer));
            CHECK(IMFSample_SetSampleTime(sample, video_time));
            CHECK(IMFSample_SetSampleDuration(sample, (i + 1) * 10000000LL / fps - video_time));
            CHECK(IMFSinkWriter_WriteSample(writer, video, sample));
            IMFSample_Release(sample);
            IMFMediaBuffer_Release(buffer);
            ++i;
        }
        else
        {
            UINT count = rate / 100, size = count * channels * (!strcmp(audio_format, "float") ? 4 : 2), k;
            IMFMediaBuffer *buffer;
            IMFSample *sample;
            BYTE *data;

            CHECK(MFCreateMemoryBuffer(size, &buffer));
            CHECK(IMFMediaBuffer_Lock(buffer, &data, NULL, NULL));
            memset(data, 0, size);
            for (k = 0; k < count; ++k)
            {
                double t = (j * count + k) / (double)rate;
                double left = 0.366 * sin(2 * M_PI * 440 * t), right = 0.366 * sin(2 * M_PI * 880 * t);
                /* The tones go to front left and front right; other channels stay silent. */
                if (!strcmp(audio_format, "float"))
                {
                    ((float *)data)[channels * k] = (float)left;
                    if (channels > 1) ((float *)data)[channels * k + 1] = (float)right;
                }
                else
                {
                    ((short *)data)[channels * k] = (short)(left * 32767);
                    if (channels > 1) ((short *)data)[channels * k + 1] = (short)(right * 32767);
                }
            }
            CHECK(IMFMediaBuffer_Unlock(buffer));
            CHECK(IMFMediaBuffer_SetCurrentLength(buffer, size));
            CHECK(MFCreateSample(&sample));
            CHECK(IMFSample_AddBuffer(sample, buffer));
            CHECK(IMFSample_SetSampleTime(sample, audio_time));
            CHECK(IMFSample_SetSampleDuration(sample, 100000));
            CHECK(IMFSinkWriter_WriteSample(writer, audio, sample));
            IMFSample_Release(sample);
            IMFMediaBuffer_Release(buffer);
            ++j;
        }
    }

    CHECK(IMFSinkWriter_GetStatistics(writer, video, &stats));
    CHECK(IMFSinkWriter_Finalize(writer));
    if (async)
    {
        if (WaitForSingleObject(callback.finalized, 120000)) { printf("{\"ok\": false, \"step\": \"OnFinalize\"}\n"); return 1; }
        CHECK(callback.status);
    }
    IMFSinkWriter_Release(writer);
    MFShutdown();
    printf("{\"ok\": true, \"frames\": %u, \"video_samples_received\": %I64u, \"ms\": %lu}\n",
            frames, stats.qwNumSamplesReceived, GetTickCount() - start);
    return 0;
}
