/* The Mac side of the REC-15 audio device test: makes a device appear and disappear, moves
 * the Mac's default devices and says which devices a process plays to. One JSON object per
 * line on stdout.
 *
 *   audio-switch list
 *   audio-switch defaults
 *   audio-switch set-default output|input UID
 *   audio-switch create UID NAME SUBDEVICE_UID   a public aggregate device of one real device:
 *                                                to programs, a new device that came and went
 *   audio-switch destroy UID
 *   audio-switch cleanup PREFIX                  destroys aggregate devices whose UID starts so
 *   audio-switch who PID                         the devices PID's audio runs on (macOS 14+)
 */
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static AudioObjectPropertyAddress address(AudioObjectPropertySelector selector, AudioObjectPropertyScope scope)
{
    AudioObjectPropertyAddress a = { selector, scope, kAudioObjectPropertyElementMain };
    return a;
}

static UInt32 u32(AudioObjectID object, AudioObjectPropertySelector selector)
{
    AudioObjectPropertyAddress a = address(selector, kAudioObjectPropertyScopeGlobal);
    UInt32 value = 0, size = sizeof(value);
    AudioObjectGetPropertyData(object, &a, 0, NULL, &size, &value);
    return value;
}

static void string(AudioObjectID object, AudioObjectPropertySelector selector, char *buffer, size_t size)
{
    AudioObjectPropertyAddress a = address(selector, kAudioObjectPropertyScopeGlobal);
    CFStringRef value = NULL;
    UInt32 length = sizeof(value);

    buffer[0] = 0;
    if (AudioObjectGetPropertyData(object, &a, 0, NULL, &length, &value) == noErr && value)
    {
        CFStringGetCString(value, buffer, (CFIndex)size, kCFStringEncodingUTF8);
        CFRelease(value);
    }
}

static UInt32 channels(AudioObjectID device, AudioObjectPropertyScope scope)
{
    AudioObjectPropertyAddress a = address(kAudioDevicePropertyStreamConfiguration, scope);
    AudioBufferList *list;
    UInt32 size = 0, total = 0, i;

    if (AudioObjectGetPropertyDataSize(device, &a, 0, NULL, &size) != noErr || !size) return 0;
    list = malloc(size);
    if (AudioObjectGetPropertyData(device, &a, 0, NULL, &size, list) == noErr)
        for (i = 0; i < list->mNumberBuffers; i++) total += list->mBuffers[i].mNumberChannels;
    free(list);
    return total;
}

static UInt32 devices(AudioObjectID *ids, UInt32 max)
{
    AudioObjectPropertyAddress a = address(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal);
    UInt32 size = max * sizeof(*ids);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, ids) != noErr) return 0;
    return size / sizeof(*ids);
}

static AudioObjectID by_uid(const char *uid)
{
    AudioObjectID ids[256];
    UInt32 count = devices(ids, 256), i;
    char buffer[256];

    for (i = 0; i < count; i++)
    {
        string(ids[i], kAudioDevicePropertyDeviceUID, buffer, sizeof(buffer));
        if (!strcmp(buffer, uid)) return ids[i];
    }
    return kAudioObjectUnknown;
}

static void print_device(AudioObjectID id)
{
    char uid[256], name[256];
    string(id, kAudioDevicePropertyDeviceUID, uid, sizeof(uid));
    string(id, kAudioObjectPropertyName, name, sizeof(name));
    printf("{\"id\":%u,\"uid\":\"%s\",\"name\":\"%s\",\"transport\":\"%.4s\",\"in\":%u,\"out\":%u}\n", (unsigned)id,
           uid, name, (char *)&(UInt32){ CFSwapInt32HostToBig(u32(id, kAudioDevicePropertyTransportType)) },
           (unsigned)channels(id, kAudioObjectPropertyScopeInput), (unsigned)channels(id, kAudioObjectPropertyScopeOutput));
}

static int set_default(const char *which, const char *uid)
{
    AudioObjectPropertyAddress a = address(strcmp(which, "input") ? kAudioHardwarePropertyDefaultOutputDevice
                                                                    : kAudioHardwarePropertyDefaultInputDevice,
                                           kAudioObjectPropertyScopeGlobal);
    AudioObjectID id = by_uid(uid);
    OSStatus sc;

    if (id == kAudioObjectUnknown) { printf("{\"error\":\"no device %s\"}\n", uid); return 1; }
    sc = AudioObjectSetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, sizeof(id), &id);
    printf("{\"set_default\":\"%s\",\"uid\":\"%s\",\"status\":%d}\n", which, uid, (int)sc);
    return sc != noErr;
}

static int create(const char *uid, const char *name, const char *sub)
{
    CFMutableDictionaryRef description = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                                   &kCFTypeDictionaryValueCallBacks);
    CFMutableDictionaryRef subdevice = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                                 &kCFTypeDictionaryValueCallBacks);
    CFStringRef cfuid = CFStringCreateWithCString(NULL, uid, kCFStringEncodingUTF8);
    CFStringRef cfname = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
    CFStringRef cfsub = CFStringCreateWithCString(NULL, sub, kCFStringEncodingUTF8);
    CFArrayRef list;
    int zero = 0;
    CFNumberRef cfzero = CFNumberCreate(NULL, kCFNumberIntType, &zero);
    AudioObjectID id = kAudioObjectUnknown;
    OSStatus sc;
    int tries;

    CFDictionarySetValue(subdevice, CFSTR(kAudioSubDeviceUIDKey), cfsub);
    list = CFArrayCreate(NULL, (const void **)&subdevice, 1, &kCFTypeArrayCallBacks);
    CFDictionarySetValue(description, CFSTR(kAudioAggregateDeviceUIDKey), cfuid);
    CFDictionarySetValue(description, CFSTR(kAudioAggregateDeviceNameKey), cfname);
    CFDictionarySetValue(description, CFSTR(kAudioAggregateDeviceSubDeviceListKey), list);
    CFDictionarySetValue(description, CFSTR(kAudioAggregateDeviceMainSubDeviceKey), cfsub);
    /* Public, so other processes (Wine) see it. */
    CFDictionarySetValue(description, CFSTR(kAudioAggregateDeviceIsPrivateKey), cfzero);
    sc = AudioHardwareCreateAggregateDevice(description, &id);
    /* The device takes a moment to get its streams. */
    for (tries = 0; sc == noErr && tries < 50 && !channels(id, kAudioObjectPropertyScopeOutput)
                    && !channels(id, kAudioObjectPropertyScopeInput); tries++)
        usleep(100000);
    printf("{\"created\":\"%s\",\"id\":%u,\"status\":%d}\n", uid, (unsigned)id, (int)sc);
    return sc != noErr;
}

static int destroy(const char *uid)
{
    AudioObjectID id = by_uid(uid);
    OSStatus sc = id == kAudioObjectUnknown ? -1 : AudioHardwareDestroyAggregateDevice(id);
    printf("{\"destroyed\":\"%s\",\"status\":%d}\n", uid, (int)sc);
    return sc != noErr;
}

static int cleanup(const char *prefix)
{
    AudioObjectID ids[256];
    UInt32 count = devices(ids, 256), i;
    char uid[256];

    for (i = 0; i < count; i++)
    {
        string(ids[i], kAudioDevicePropertyDeviceUID, uid, sizeof(uid));
        if (!strncmp(uid, prefix, strlen(prefix))) destroy(uid);
    }
    return 0;
}

static int who(pid_t pid)
{
    AudioObjectPropertyAddress a = address(kAudioHardwarePropertyProcessObjectList, kAudioObjectPropertyScopeGlobal);
    AudioObjectID processes[512];
    UInt32 size = sizeof(processes), i, j;

    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, processes) != noErr) return 1;
    for (i = 0; i < size / sizeof(*processes); i++)
    {
        AudioObjectPropertyAddress pa = address(kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal);
        pid_t owner = 0;
        UInt32 psize = sizeof(owner);
        AudioObjectID used[64];
        UInt32 usize = sizeof(used);
        AudioObjectPropertyAddress da = address(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput);
        char uid[256];

        if (AudioObjectGetPropertyData(processes[i], &pa, 0, NULL, &psize, &owner) != noErr || owner != pid) continue;
        printf("{\"pid\":%d,\"running_output\":%u,\"output\":[", (int)pid,
               (unsigned)u32(processes[i], kAudioProcessPropertyIsRunningOutput));
        if (AudioObjectGetPropertyData(processes[i], &da, 0, NULL, &usize, used) == noErr)
            for (j = 0; j < usize / sizeof(*used); j++)
            {
                string(used[j], kAudioDevicePropertyDeviceUID, uid, sizeof(uid));
                printf("%s\"%s\"", j ? "," : "", uid);
            }
        printf("]}\n");
        return 0;
    }
    printf("{\"pid\":%d,\"running_output\":0,\"output\":[]}\n", (int)pid);
    return 0;
}

int main(int argc, char **argv)
{
    AudioObjectID ids[256];
    UInt32 count, i;
    char out[256], in[256];

    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc >= 2 && !strcmp(argv[1], "list"))
    {
        count = devices(ids, 256);
        for (i = 0; i < count; i++) print_device(ids[i]);
        return 0;
    }
    if (argc >= 2 && !strcmp(argv[1], "defaults"))
    {
        string(u32(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice), kAudioDevicePropertyDeviceUID, out, sizeof(out));
        string(u32(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultInputDevice), kAudioDevicePropertyDeviceUID, in, sizeof(in));
        printf("{\"output\":\"%s\",\"input\":\"%s\"}\n", out, in);
        return 0;
    }
    if (argc >= 4 && !strcmp(argv[1], "set-default")) return set_default(argv[2], argv[3]);
    if (argc >= 5 && !strcmp(argv[1], "create")) return create(argv[2], argv[3], argv[4]);
    if (argc >= 3 && !strcmp(argv[1], "destroy")) return destroy(argv[2]);
    if (argc >= 3 && !strcmp(argv[1], "cleanup")) return cleanup(argv[2]);
    if (argc >= 3 && !strcmp(argv[1], "who")) return who((pid_t)atoi(argv[2]));
    fprintf(stderr, "usage: audio-switch list|defaults|set-default|create|destroy|cleanup|who ...\n");
    return 2;
}
