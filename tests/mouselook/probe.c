/* Shooter-style cursor handling under Wine, for the mouselook driver.
 *
 * Takes the foreground, then runs two phases of simulated frames that each
 * move the cursor (SetCursorPos, alternating between two points around the
 * window centre, as a game re-centring after mouse motion does) and read it
 * back (GetCursorPos):
 *   visible  cursor shown and free: the Mac pointer must follow every call;
 *   aiming   cursor hidden and confined to the window (ShowCursor, ClipCursor),
 *            the state in which mouselook engages.
 * Each frame also re-centres to the position already set, which is only a
 * wineserver round trip (no driver work): the baseline cost of any cursor call.
 * The rest of a frame is 2 ms of busy work, so the Mac stays as awake as it is
 * under a game rather than measuring idle wake-up delays.
 * After each phase it checks that a position set before a 250 ms pause still
 * reads back (Wine asks the driver after 100 ms without cursor updates) and,
 * after aiming ends, that the pointer reappears where the game left it.
 * One JSON line per phase goes to stdout.
 */
#include <windows.h>
#include <stdio.h>

static LARGE_INTEGER frequency;
static double now_us(void)
{
    LARGE_INTEGER t;
    QueryPerformanceCounter(&t);
    return t.QuadPart * 1e6 / frequency.QuadPart;
}

static LRESULT CALLBACK window_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam)
{
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

static void busy(double us)
{
    double end = now_us() + us;
    while (now_us() < end);
}

static void pump(void)
{
    MSG msg;
    while (PeekMessageW(&msg, 0, 0, 0, PM_REMOVE))
    {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
}

static void settle(DWORD ms)
{
    DWORD end = GetTickCount() + ms;
    while ((int)(end - GetTickCount()) > 0)
    {
        pump();
        Sleep(5);
    }
}

static int compare(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

static BOOL same_point(POINT a, POINT b)
{
    return abs(a.x - b.x) <= 1 && abs(a.y - b.y) <= 1;
}

static void phase(const char *name, HWND hwnd, BOOL aiming, int frames)
{
    RECT client;
    POINT origin = {0, 0}, center, last, idle, after;
    double set_total = 0, set_max = 0, get_total = 0, same_total = 0, frame_total = 0, frame_max = 0, start;
    double set_times[1024];
    int i, mismatches = 0;

    GetClientRect(hwnd, &client);
    ClientToScreen(hwnd, &origin);
    center.x = origin.x + client.right / 2;
    center.y = origin.y + client.bottom / 2;

    if (aiming)
    {
        RECT clip = {origin.x, origin.y, origin.x + client.right, origin.y + client.bottom};
        while (ShowCursor(FALSE) >= 0);
        ClipCursor(&clip);
    }
    settle(500);

    start = now_us();
    for (i = 0; i < frames; i++)
    {
        POINT target = {center.x + (i & 1 ? 8 : -8), center.y + (i & 1 ? 6 : -6)}, read;
        double t0 = now_us(), t1, t2, t3;

        pump();
        SetCursorPos(target.x, target.y);
        t1 = now_us();
        GetCursorPos(&read);
        t2 = now_us();
        SetCursorPos(target.x, target.y);
        t3 = now_us();
        same_total += t3 - t2;
        if (!same_point(read, target)) mismatches++;
        set_total += t1 - t0;
        set_times[i] = t1 - t0;
        if (t1 - t0 > set_max) set_max = t1 - t0;
        get_total += t2 - t1;
        busy(2000);  /* the rest of a simulated frame */
        if (now_us() - t0 > frame_max) frame_max = now_us() - t0;
    }
    frame_total = now_us() - start;
    qsort(set_times, frames, sizeof(set_times[0]), compare);

    last.x = center.x + 21;
    last.y = center.y + 13;
    SetCursorPos(last.x, last.y);
    settle(250);
    GetCursorPos(&idle);

    if (aiming)
    {
        ClipCursor(NULL);
        while (ShowCursor(TRUE) < 0);
    }
    settle(600);
    GetCursorPos(&after);

    printf("{\"phase\":\"%s\",\"frames\":%d,\"frame_mean_us\":%.1f,\"frame_max_us\":%.1f,"
           "\"setpos_mean_us\":%.1f,\"setpos_max_us\":%.1f,\"setpos_median_us\":%.1f,\"setpos_p99_us\":%.1f,\"server_roundtrip_us\":%.1f,\"getpos_mean_us\":%.1f,\"readback_mismatches\":%d,"
           "\"idle_position_ok\":%s,\"pointer_after_ok\":%s,\"foreground\":%s}\n",
           name, frames, frame_total / frames, frame_max, set_total / frames, set_max, set_times[frames / 2], set_times[frames * 99 / 100], same_total / frames, get_total / frames,
           mismatches, same_point(idle, last) ? "true" : "false", same_point(after, last) ? "true" : "false",
           GetForegroundWindow() == hwnd ? "true" : "false");
    fflush(stdout);
}

int main(void)
{
    WNDCLASSW cls = {0};
    HWND hwnd;
    RAWINPUTDEVICE mouse = {1, 2, 0, NULL};
    int wait;

    QueryPerformanceFrequency(&frequency);
    cls.lpfnWndProc = window_proc;
    cls.hInstance = GetModuleHandleW(NULL);
    cls.hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW);
    cls.lpszClassName = L"MouselookProbe";
    RegisterClassW(&cls);
    hwnd = CreateWindowExW(0, L"MouselookProbe", L"Mouselook probe", WS_OVERLAPPEDWINDOW,
                           200, 150, 900, 600, NULL, NULL, cls.hInstance, NULL);
    ShowWindow(hwnd, SW_SHOWNORMAL);
    UpdateWindow(hwnd);
    SetForegroundWindow(hwnd);
    mouse.hwndTarget = hwnd;
    RegisterRawInputDevices(&mouse, 1, sizeof(mouse));

    for (wait = 0; wait < 60 && GetForegroundWindow() != hwnd; wait++)
        settle(50);
    settle(300);

    phase("visible", hwnd, FALSE, 600);
    phase("aiming", hwnd, TRUE, 600);
    settle(1500);  /* the driver writes input statistics once a second */

    DestroyWindow(hwnd);
    return 0;
}
