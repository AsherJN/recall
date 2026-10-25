/* Plays silence the way a game does and reports what Wine tells it about audio devices
 * (REC-15). One JSON object per line on stdout.
 *
 *   audio-probe.exe follow SECONDS    reopens on the new default when told it changed,
 *                                     and on AUDCLNT_E_DEVICE_INVALIDATED
 *   audio-probe.exe stubborn SECONDS  ignores default changes (only logs them) and reopens
 *                                     only on AUDCLNT_E_DEVICE_INVALIDATED
 *
 * Every half second it prints the device it plays to and how many frames that device took
 * since the last line (a device that is gone takes none). Silence only: nothing is heard.
 * Capture devices are only named, never opened, so no microphone permission is involved. */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <initguid.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <propsys.h>
#include <stdio.h>
#include <string.h>

DEFINE_PROPERTYKEY(PROBE_PKEY_Device_FriendlyName, 0xa45c254e, 0xdf1c, 0x4efd, 0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0, 14);

static CRITICAL_SECTION print_lock;
static IMMDeviceEnumerator *enumerator;
static volatile LONG default_changed;
static BOOL follow;

static void json_string(const WCHAR *text)
{
    putchar('"');
    for (; text && *text; text++)
    {
        if (*text == '"' || *text == '\\') printf("\\%c", (char)*text);
        else if (*text < 0x20) printf("\\u%04x", *text);
        else if (*text < 0x80) putchar((char)*text);
        else printf("\\u%04x", *text);
    }
    putchar('"');
}

static WCHAR *device_name(IMMDevice *device, WCHAR *buffer, size_t size)
{
    IPropertyStore *store;
    PROPVARIANT pv;

    buffer[0] = 0;
    if (SUCCEEDED(IMMDevice_OpenPropertyStore(device, STGM_READ, &store)))
    {
        PropVariantInit(&pv);
        if (SUCCEEDED(IPropertyStore_GetValue(store, &PROBE_PKEY_Device_FriendlyName, &pv)) && pv.vt == VT_LPWSTR)
            lstrcpynW(buffer, pv.pwszVal, (int)size);
        PropVariantClear(&pv);
        IPropertyStore_Release(store);
    }
    return buffer;
}

static WCHAR *name_of_id(const WCHAR *id, WCHAR *buffer, size_t size)
{
    IMMDevice *device;

    buffer[0] = 0;
    if (id && SUCCEEDED(IMMDeviceEnumerator_GetDevice(enumerator, id, &device)))
    {
        device_name(device, buffer, size);
        IMMDevice_Release(device);
    }
    return buffer;
}

static void log_default(const char *event, EDataFlow flow, ERole role, const WCHAR *id)
{
    WCHAR name[256];

    name_of_id(id, name, ARRAYSIZE(name));
    EnterCriticalSection(&print_lock);
    printf("{\"t\":%llu,\"event\":\"%s\",\"flow\":\"%s\",\"role\":%u,\"id\":", GetTickCount64(), event,
           flow == eRender ? "render" : "capture", role);
    json_string(id);
    printf(",\"name\":");
    json_string(name);
    printf("}\n");
    fflush(stdout);
    LeaveCriticalSection(&print_lock);
}

static void log_device(const char *event, const WCHAR *id, DWORD state)
{
    WCHAR name[256];

    name_of_id(id, name, ARRAYSIZE(name));
    EnterCriticalSection(&print_lock);
    printf("{\"t\":%llu,\"event\":\"%s\",\"id\":", GetTickCount64(), event);
    json_string(id);
    printf(",\"name\":");
    json_string(name);
    if (state) printf(",\"state\":%lu", state);
    printf("}\n");
    fflush(stdout);
    LeaveCriticalSection(&print_lock);
}

static void log_text(const char *event, const char *detail, HRESULT hr)
{
    EnterCriticalSection(&print_lock);
    printf("{\"t\":%llu,\"event\":\"%s\",\"detail\":\"%s\",\"hr\":\"%08lx\"}\n", GetTickCount64(), event, detail, hr);
    fflush(stdout);
    LeaveCriticalSection(&print_lock);
}

/* IMMNotificationClient */
static HRESULT WINAPI client_QueryInterface(IMMNotificationClient *iface, REFIID riid, void **out)
{
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IMMNotificationClient))
    {
        *out = iface;
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}
static ULONG WINAPI client_AddRef(IMMNotificationClient *iface) { return 2; }
static ULONG WINAPI client_Release(IMMNotificationClient *iface) { return 1; }
static HRESULT WINAPI client_OnDeviceStateChanged(IMMNotificationClient *iface, const WCHAR *id, DWORD state)
{
    log_device("state", id, state);
    return S_OK;
}
static HRESULT WINAPI client_OnDeviceAdded(IMMNotificationClient *iface, const WCHAR *id)
{
    log_device("added", id, 0);
    return S_OK;
}
static HRESULT WINAPI client_OnDeviceRemoved(IMMNotificationClient *iface, const WCHAR *id)
{
    log_device("removed", id, 0);
    return S_OK;
}
static HRESULT WINAPI client_OnDefaultDeviceChanged(IMMNotificationClient *iface, EDataFlow flow, ERole role, const WCHAR *id)
{
    log_default("default", flow, role, id);
    if (flow == eRender && role == eConsole) InterlockedExchange(&default_changed, 1);
    return S_OK;
}
static HRESULT WINAPI client_OnPropertyValueChanged(IMMNotificationClient *iface, const WCHAR *id, const PROPERTYKEY key)
{
    return S_OK;
}
static IMMNotificationClientVtbl client_vtbl =
{
    client_QueryInterface, client_AddRef, client_Release, client_OnDeviceStateChanged, client_OnDeviceAdded,
    client_OnDeviceRemoved, client_OnDefaultDeviceChanged, client_OnPropertyValueChanged,
};
static IMMNotificationClient client = { &client_vtbl };

struct player
{
    IMMDevice *device;
    IAudioClient *audio;
    IAudioRenderClient *render;
    UINT32 frames;
    WCHAR id[128], name[256];
};

static void close_player(struct player *p)
{
    if (p->audio) IAudioClient_Stop(p->audio);
    if (p->render) IAudioRenderClient_Release(p->render);
    if (p->audio) IAudioClient_Release(p->audio);
    if (p->device) IMMDevice_Release(p->device);
    memset(p, 0, sizeof(*p));
}

static HRESULT open_player(struct player *p)
{
    WAVEFORMATEX *format = NULL;
    WCHAR *id = NULL;
    HRESULT hr;

    close_player(p);
    if (FAILED(hr = IMMDeviceEnumerator_GetDefaultAudioEndpoint(enumerator, eRender, eConsole, &p->device)))
        return hr;
    IMMDevice_GetId(p->device, &id);
    lstrcpynW(p->id, id ? id : L"", ARRAYSIZE(p->id));
    CoTaskMemFree(id);
    device_name(p->device, p->name, ARRAYSIZE(p->name));
    if (FAILED(hr = IMMDevice_Activate(p->device, &IID_IAudioClient, CLSCTX_ALL, NULL, (void **)&p->audio)) ||
        FAILED(hr = IAudioClient_GetMixFormat(p->audio, &format)) ||
        FAILED(hr = IAudioClient_Initialize(p->audio, AUDCLNT_SHAREMODE_SHARED, 0, 1000000, 0, format, NULL)) ||
        FAILED(hr = IAudioClient_GetBufferSize(p->audio, &p->frames)) ||
        FAILED(hr = IAudioClient_GetService(p->audio, &IID_IAudioRenderClient, (void **)&p->render)) ||
        FAILED(hr = IAudioClient_Start(p->audio)))
    {
        CoTaskMemFree(format);
        log_text("open_failed", "render", hr);
        close_player(p);
        return hr;
    }
    CoTaskMemFree(format);
    EnterCriticalSection(&print_lock);
    printf("{\"t\":%llu,\"event\":\"playing\",\"id\":", GetTickCount64());
    json_string(p->id);
    printf(",\"name\":");
    json_string(p->name);
    printf("}\n");
    fflush(stdout);
    LeaveCriticalSection(&print_lock);
    return S_OK;
}

/* Fills what the device has taken with silence; returns frames written, or a failure. */
static HRESULT feed(struct player *p, UINT32 *written)
{
    UINT32 padding;
    BYTE *data;
    HRESULT hr;

    *written = 0;
    if (FAILED(hr = IAudioClient_GetCurrentPadding(p->audio, &padding))) return hr;
    if (padding >= p->frames) return S_OK;
    if (FAILED(hr = IAudioRenderClient_GetBuffer(p->render, p->frames - padding, &data))) return hr;
    if (FAILED(hr = IAudioRenderClient_ReleaseBuffer(p->render, p->frames - padding, AUDCLNT_BUFFERFLAGS_SILENT))) return hr;
    *written = p->frames - padding;
    return S_OK;
}

int main(int argc, char **argv)
{
    struct player player = { 0 };
    ULONGLONG end, next_report;
    UINT64 taken = 0;
    IMMDevice *device;
    WCHAR *id;
    HRESULT hr;

    if (argc < 3 || (strcmp(argv[1], "follow") && strcmp(argv[1], "stubborn")))
    {
        fprintf(stderr, "usage: audio-probe.exe follow|stubborn SECONDS\n");
        return 2;
    }
    follow = !strcmp(argv[1], "follow");
    InitializeCriticalSection(&print_lock);
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(hr = CoCreateInstance(&CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL, &IID_IMMDeviceEnumerator,
                                     (void **)&enumerator)))
    {
        log_text("enumerator_failed", "", hr);
        return 1;
    }
    IMMDeviceEnumerator_RegisterEndpointNotificationCallback(enumerator, &client);
    if (SUCCEEDED(IMMDeviceEnumerator_GetDefaultAudioEndpoint(enumerator, eCapture, eCommunications, &device)))
    {
        IMMDevice_GetId(device, &id);
        log_default("start_default", eCapture, eCommunications, id);
        CoTaskMemFree(id);
        IMMDevice_Release(device);
    }
    open_player(&player);

    end = GetTickCount64() + (ULONGLONG)atoi(argv[2]) * 1000;
    next_report = GetTickCount64() + 500;
    while (GetTickCount64() < end)
    {
        UINT32 written = 0;

        if (InterlockedExchange(&default_changed, 0) && follow)
        {
            log_text("reopen", "default_changed", S_OK);
            open_player(&player);
        }
        if (player.audio)
        {
            hr = feed(&player, &written);
            if (hr == AUDCLNT_E_DEVICE_INVALIDATED)
            {
                log_text("invalidated", "render", hr);
                open_player(&player);
            }
            else if (FAILED(hr))
                log_text("feed_failed", "render", hr);
            else
                taken += written;
        }
        else if (GetTickCount64() >= next_report)
            open_player(&player);
        if (GetTickCount64() >= next_report)
        {
            EnterCriticalSection(&print_lock);
            printf("{\"t\":%llu,\"event\":\"report\",\"id\":", GetTickCount64());
            json_string(player.id);
            printf(",\"taken\":%llu}\n", (unsigned long long)taken);
            fflush(stdout);
            LeaveCriticalSection(&print_lock);
            taken = 0;
            next_report += 500;
        }
        Sleep(10);
    }
    IMMDeviceEnumerator_UnregisterEndpointNotificationCallback(enumerator, &client);
    close_player(&player);
    IMMDeviceEnumerator_Release(enumerator);
    CoUninitialize();
    log_text("done", "", S_OK);
    return 0;
}
