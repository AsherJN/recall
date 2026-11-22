/* Recall #80/#81: a font instance id that outlives its font.
 *
 * A program gets a realized font's instance id from GetFontRealizationInfo and reads the font's
 * file through GetFontFileInfo/GetFontFileData (Wine's DirectWrite does, for fonts loaded from
 * memory). Wine frees a font once it is unused and eleven newer unused fonts exist; the id's entry in
 * win32u's handle table then links the free list. Wine still accepted the id and read the table as
 * a font: GetFontFileData faulted inside the font code with the font lock held, the fault went
 * back to the program as a return value, and the lock was never released, so the next thread to
 * touch a font waited forever (Battle.net's install window).
 *
 * Realizes FONTS fonts at once, releases them all (so all but the last eleven are freed, one after the
 * other, with no handle allocated in between), has one thread ask for each stale id's file and then
 * another select a font, giving each ten seconds. Prints one JSON line. */
#include <windows.h>
#include <stdio.h>
#include <string.h>

#define FONTS 40
#define STALE 25  /* Wine keeps the eleven fonts released last; the first 25 are certainly freed */

struct font_realization_info
{
    DWORD size, flags, cache_num, instance_id, file_count;
    WORD face_index, simulations;
};

struct font_fileinfo
{
    FILETIME writetime;
    LARGE_INTEGER size;
    WCHAR path[1];
};

static BOOL (WINAPI *pGetFontRealizationInfo)(HDC, struct font_realization_info *);
static BOOL (WINAPI *pGetFontFileInfo)(DWORD, DWORD, struct font_fileinfo *, SIZE_T, SIZE_T *);
static BOOL (WINAPI *pGetFontFileData)(DWORD, DWORD, UINT64, void *, SIZE_T);

static HFONT create_font(int height)
{
    return CreateFontW(height, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                       CLIP_DEFAULT_PRECIS, DEFAULT_QUALITY, DEFAULT_PITCH, L"Tahoma");
}

static DWORD WINAPI select_a_font(void *arg)
{
    HDC dc = CreateCompatibleDC(NULL);
    HFONT font = create_font(200), old = SelectObject(dc, font);
    TEXTMETRICW metrics;
    BOOL ok = GetTextMetricsW(dc, &metrics);

    SelectObject(dc, old);
    DeleteObject(font);
    DeleteDC(dc);
    return ok ? 0 : 1;
}

static LONG info_accepted, data_accepted;

/* on an engine without the change the second call already waits for the lock the first one left held */
static DWORD WINAPI read_stale_ids(void *arg)
{
    const DWORD *id = arg;
    char buffer[64];
    int i;

    for (i = 0; i < STALE; i++)
    {
        struct font_fileinfo info;
        SIZE_T needed = 0;

        if (!id[i]) continue;
        if (pGetFontFileInfo(id[i], 0, &info, sizeof(info), &needed)) InterlockedIncrement(&info_accepted);
        if (pGetFontFileData(id[i], 0, 0, buffer, 0)) InterlockedIncrement(&data_accepted);
        if (pGetFontFileData(id[i], 0, 0, buffer, 12)) InterlockedIncrement(&data_accepted);
    }
    return 0;
}

int main(void)
{
    HMODULE gdi32 = GetModuleHandleW(L"gdi32.dll");
    HDC dc[FONTS];
    HFONT font[FONTS], old[FONTS];
    DWORD id[FONTS], code = 1;
    int i, realized = 0, live_data = 0;
    char buffer[64];
    HANDLE thread;
    const char *after, *stale = "returned";

    pGetFontRealizationInfo = (void *)GetProcAddress(gdi32, "GetFontRealizationInfo");
    pGetFontFileInfo = (void *)GetProcAddress(gdi32, "GetFontFileInfo");
    pGetFontFileData = (void *)GetProcAddress(gdi32, "GetFontFileData");
    if (!pGetFontRealizationInfo || !pGetFontFileInfo || !pGetFontFileData)
    {
        printf("{\"error\":\"gdi32 lacks the font file functions\"}\n");
        return 2;
    }

    for (i = 0; i < FONTS; i++)
    {
        struct font_realization_info info;
        TEXTMETRICW metrics;

        memset(&info, 0, sizeof(info));
        info.size = sizeof(info);

        dc[i] = CreateCompatibleDC(NULL);
        font[i] = create_font(20 + i);
        old[i] = SelectObject(dc[i], font[i]);
        GetTextMetricsW(dc[i], &metrics);
        id[i] = pGetFontRealizationInfo(dc[i], &info) ? info.instance_id : 0;
        if (id[i]) realized++;
    }
    /* a live id works: the first bytes of the font's file */
    if (id[0] && pGetFontFileData(id[0], 0, 0, buffer, 12) == TRUE) live_data = 1;

    for (i = 0; i < FONTS; i++)
    {
        SelectObject(dc[i], old[i]);
        DeleteObject(font[i]);
        DeleteDC(dc[i]);
    }
    thread = CreateThread(NULL, 0, read_stale_ids, id, 0, NULL);
    if (WaitForSingleObject(thread, 10000) != WAIT_OBJECT_0) stale = "blocked";

    thread = CreateThread(NULL, 0, select_a_font, NULL, 0, NULL);
    if (WaitForSingleObject(thread, 10000) == WAIT_OBJECT_0)
    {
        GetExitCodeThread(thread, &code);
        after = code ? "failed" : "ok";
    }
    else after = "blocked";

    printf("{\"realized\":%d,\"live_id_read\":%s,\"stale_ids\":%d,\"stale_reads\":\"%s\","
           "\"stale_info_accepted\":%ld,\"stale_data_accepted\":%ld,\"font_use_afterwards\":\"%s\"}\n",
           realized, live_data ? "true" : "false", STALE, stale, info_accepted, data_accepted, after);
    fflush(stdout);
    /* a blocked thread holds win32u's lock: leave without waiting for it */
    TerminateProcess(GetCurrentProcess(), strcmp(after, "ok") || strcmp(stale, "returned") ? 1 : 0);
    return 0;
}
