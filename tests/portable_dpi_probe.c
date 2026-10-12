/* Prints, as one JSON line, the DPI this program sees: the system's, the screen device's,
 * each monitor's (effective and raw), a new window's, and the DPI Wine records for each
 * display in its shared cache. Copied to Battle.net.exe or Overwatch.exe, it shows
 * whether WINE_APP_DPI reaches only the programs it names (tests/run_dpi_probe.py).
 * Usage: probe pmv2|system|unaware [hold-ms]; hold-ms keeps it (and the session) open. */
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <shellscalingapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static BOOL CALLBACK monitor(HMONITOR handle, HDC hdc, RECT *rect, LPARAM first)
{
    UINT ex = 0, ey = 0, rx = 0, ry = 0;
    (void)hdc;
    GetDpiForMonitor(handle, MDT_EFFECTIVE_DPI, &ex, &ey);
    GetDpiForMonitor(handle, MDT_RAW_DPI, &rx, &ry);
    printf("%s{\"effective\":%u,\"raw\":%u,\"rect\":[%ld,%ld,%ld,%ld]}", *(int *)first ? "" : ",", ex, rx,
           rect->left, rect->top, rect->right, rect->bottom);
    *(int *)first = 0;
    return TRUE;
}

static void cached_dpis(void)
{
    static const char video[] = "System\\CurrentControlSet\\Hardware Profiles\\Current\\System\\CurrentControlSet\\Control\\Video";
    HKEY base, sources, source;
    char name[256], path[512];
    DWORD i, j, size, dpi, type, first = 1;
    printf(",\"cached\":[");
    if (!RegOpenKeyExA(HKEY_LOCAL_MACHINE, video, 0, KEY_READ, &base)) {
        for (i = 0; size = sizeof(name), !RegEnumKeyExA(base, i, name, &size, NULL, NULL, NULL, NULL); i++) {
            snprintf(path, sizeof(path), "%s\\Sources", name);
            if (RegOpenKeyExA(base, path, 0, KEY_READ, &sources)) continue;
            for (j = 0; size = sizeof(name), !RegEnumKeyExA(sources, j, name, &size, NULL, NULL, NULL, NULL); j++) {
                if (RegOpenKeyExA(sources, name, 0, KEY_READ, &source)) continue;
                size = sizeof(dpi);
                if (!RegQueryValueExA(source, "Dpi", NULL, &type, (BYTE *)&dpi, &size) && type == REG_DWORD) {
                    printf("%s%lu", first ? "" : ",", dpi);
                    first = 0;
                }
                RegCloseKey(source);
            }
            RegCloseKey(sources);
        }
        RegCloseKey(base);
    }
    printf("]");
}

int main(int argc, char **argv)
{
    char image[MAX_PATH], *name;
    int first = 1;
    HWND window;
    RECT rect;
    HDC dc;
    if (argc < 2) return 2;
    if (!strcmp(argv[1], "pmv2")) SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    else if (!strcmp(argv[1], "system")) SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_SYSTEM_AWARE);
    else if (strcmp(argv[1], "unaware")) return 2;
    GetModuleFileNameA(NULL, image, sizeof(image));
    name = strrchr(image, '\\') ? strrchr(image, '\\') + 1 : image;
    dc = GetDC(NULL);
    printf("{\"name\":\"%s\",\"awareness\":\"%s\",\"system\":%u,\"caps\":%d,\"screen\":[%d,%d],\"monitors\":[",
           name, argv[1], GetDpiForSystem(), GetDeviceCaps(dc, LOGPIXELSX), GetSystemMetrics(SM_CXSCREEN),
           GetSystemMetrics(SM_CYSCREEN));
    ReleaseDC(NULL, dc);
    EnumDisplayMonitors(NULL, NULL, monitor, (LPARAM)&first);
    printf("]");
    window = CreateWindowExA(0, "STATIC", "dpi probe", WS_OVERLAPPEDWINDOW, 0, 0, 400, 300, NULL, NULL, NULL, NULL);
    GetWindowRect(window, &rect);
    printf(",\"window\":{\"dpi\":%u,\"size\":[%ld,%ld]}", GetDpiForWindow(window), rect.right - rect.left,
           rect.bottom - rect.top);
    DestroyWindow(window);
    cached_dpis();
    printf("}\n");
    fflush(stdout);
    if (argc > 2) Sleep(atoi(argv[2]));
    return 0;
}
