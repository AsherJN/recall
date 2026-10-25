/* Display-mode probe for the window driver (REC-45), built with LLVM-MinGW by run.py.
 *
 *   display_probe.exe run <log.jsonl> <go-prefix> <step>...
 *       A Direct3D 11 window that switches display modes the way Overwatch does. Its picture
 *       is green with a red border (border()), so a screenshot shows whether the whole picture
 *       fills the window: gray means it is too small, a missing border too large. Steps:
 *       fullscreen | windowed:WxH | borderless | maximize. Before the first step and after
 *       each one it logs the window's geometry, prints "ready N" and keeps presenting until
 *       the file <go-prefix>N exists.
 *   display_probe.exe inspect <exe>
 *       The same geometry for each visible top-level window of <exe> (a live game).
 *   display_probe.exe click <exe> X Y      A left click at client coordinates X, Y.
 *   display_probe.exe key <exe> VK[+VK...] Keys (hexadecimal virtual-key codes) pressed in
 *                                          order and released in reverse.
 *
 * click and key bring the window to the front and send input through Wine (SendInput),
 * never through macOS.
 */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static HWND window;
static IDXGISwapChain *chain;
static ID3D11Device *device;
static ID3D11DeviceContext *context;
static ID3D11RenderTargetView *target;
static ID3D11Texture2D *backbuffer, *pattern;

/* The border's width in backbuffer pixels: 2% of the shorter side, at least 8. */
static UINT border(UINT width, UINT height) {
    UINT shorter = width < height ? width : height, size = shorter / 50;
    return size < 8 ? 8 : size;
}

static void releaseTarget(void) {
    if (target) { ID3D11RenderTargetView_Release(target); target = NULL; }
    if (backbuffer) { ID3D11Texture2D_Release(backbuffer); backbuffer = NULL; }
    if (pattern) { ID3D11Texture2D_Release(pattern); pattern = NULL; }
}

static void makeTarget(void) {
    D3D11_TEXTURE2D_DESC desc;
    D3D11_SUBRESOURCE_DATA data = {0};
    UINT edge;
    unsigned char *pixels;
    releaseTarget();
    if (FAILED(IDXGISwapChain_GetBuffer(chain, 0, &IID_ID3D11Texture2D, (void **)&backbuffer))) return;
    ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)backbuffer, NULL, &target);
    ID3D11Texture2D_GetDesc(backbuffer, &desc);
    edge = border(desc.Width, desc.Height);
    if (!(pixels = malloc((size_t)desc.Width * desc.Height * 4))) return;
    for (UINT y = 0; y < desc.Height; y++)
        for (UINT x = 0; x < desc.Width; x++) {
            BOOL red = x < edge || y < edge || x >= desc.Width - edge || y >= desc.Height - edge;
            unsigned char *p = pixels + ((size_t)y * desc.Width + x) * 4; /* B, G, R, A */
            p[0] = 0; p[1] = red ? 0 : 255; p[2] = red ? 255 : 0; p[3] = 255;
        }
    desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = 0;
    desc.MiscFlags = 0;
    data.pSysMem = pixels;
    data.SysMemPitch = desc.Width * 4;
    ID3D11Device_CreateTexture2D(device, &desc, &data, &pattern);
    free(pixels);
}

static void resizeBuffers(UINT width, UINT height) {
    if (!chain) return;
    releaseTarget();
    IDXGISwapChain_ResizeBuffers(chain, 0, width, height, DXGI_FORMAT_UNKNOWN, 0);
    makeTarget();
}

static void present(void) {
    if (!backbuffer || !pattern) return;
    ID3D11DeviceContext_CopyResource(context, (ID3D11Resource *)backbuffer, (ID3D11Resource *)pattern);
    IDXGISwapChain_Present(chain, 1, 0);
}

static LRESULT CALLBACK proc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == WM_SIZE && chain && wparam != SIZE_MINIMIZED) {
        resizeBuffers(LOWORD(lparam), HIWORD(lparam));
        return 0;
    }
    if (message == WM_CLOSE) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(hwnd, message, wparam, lparam);
}

/* Messages and frames for at least the given time, or until the file exists. */
static void pump(DWORD milliseconds, const char *until) {
    DWORD start = GetTickCount();
    for (;;) {
        MSG msg;
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
            if (msg.message == WM_QUIT) ExitProcess(3);
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        present();
        if (until) {
            if (GetFileAttributesA(until) != INVALID_FILE_ATTRIBUTES) return;
        } else if (GetTickCount() - start >= milliseconds) return;
    }
}

static void describe(FILE *out, HWND hwnd, const char *label, int index) {
    RECT outer = {0}, client = {0};
    POINT origin = {0, 0};
    MONITORINFO monitor = {sizeof(monitor)};
    GetWindowRect(hwnd, &outer);
    GetClientRect(hwnd, &client);
    ClientToScreen(hwnd, &origin);
    GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor);
    fprintf(out, "{\"label\":\"%s\",\"index\":%d,\"hwnd\":%llu,\"style\":%lu,\"exstyle\":%lu,\"zoomed\":%s,"
            "\"foreground\":%s,\"outer\":[%ld,%ld,%ld,%ld],\"client\":[%ld,%ld],\"client_origin\":[%ld,%ld],"
            "\"monitor\":[%ld,%ld,%ld,%ld],\"work\":[%ld,%ld,%ld,%ld]",
            label, index, (unsigned long long)(ULONG_PTR)hwnd, (unsigned long)GetWindowLongW(hwnd, GWL_STYLE),
            (unsigned long)GetWindowLongW(hwnd, GWL_EXSTYLE), IsZoomed(hwnd) ? "true" : "false",
            GetForegroundWindow() == hwnd ? "true" : "false",
            outer.left, outer.top, outer.right - outer.left, outer.bottom - outer.top, client.right, client.bottom,
            origin.x, origin.y, monitor.rcMonitor.left, monitor.rcMonitor.top,
            monitor.rcMonitor.right - monitor.rcMonitor.left, monitor.rcMonitor.bottom - monitor.rcMonitor.top,
            monitor.rcWork.left, monitor.rcWork.top, monitor.rcWork.right - monitor.rcWork.left,
            monitor.rcWork.bottom - monitor.rcWork.top);
    if (hwnd == window && chain) {
        DXGI_SWAP_CHAIN_DESC desc;
        BOOL fullscreen = FALSE;
        IDXGISwapChain_GetDesc(chain, &desc);
        IDXGISwapChain_GetFullscreenState(chain, &fullscreen, NULL);
        fprintf(out, ",\"backbuffer\":[%u,%u],\"border\":%u,\"dxgi_fullscreen\":%s", desc.BufferDesc.Width,
                desc.BufferDesc.Height, border(desc.BufferDesc.Width, desc.BufferDesc.Height), fullscreen ? "true" : "false");
    }
    fprintf(out, "}\n");
    fflush(out);
}

/* As a game leaves fullscreen for a window: the DXGI request, then at once its own size. */
static void windowed(int width, int height) {
    RECT rect = {0, 0, width, height};
    IDXGISwapChain_SetFullscreenState(chain, FALSE, NULL);
    SetWindowLongW(window, GWL_STYLE, WS_OVERLAPPEDWINDOW | WS_VISIBLE);
    AdjustWindowRectEx(&rect, WS_OVERLAPPEDWINDOW, FALSE, 0);
    SetWindowPos(window, HWND_NOTOPMOST, 100, 100, rect.right - rect.left, rect.bottom - rect.top,
                 SWP_FRAMECHANGED | SWP_SHOWWINDOW);
    resizeBuffers(width, height);
}

/* A borderless window: no frame, covering the monitor. */
static void borderless(void) {
    MONITORINFO monitor = {sizeof(monitor)};
    LONG width, height;
    IDXGISwapChain_SetFullscreenState(chain, FALSE, NULL);
    GetMonitorInfoW(MonitorFromWindow(window, MONITOR_DEFAULTTOPRIMARY), &monitor);
    width = monitor.rcMonitor.right - monitor.rcMonitor.left;
    height = monitor.rcMonitor.bottom - monitor.rcMonitor.top;
    SetWindowLongW(window, GWL_STYLE, WS_POPUP | WS_VISIBLE);
    SetWindowPos(window, HWND_TOP, monitor.rcMonitor.left, monitor.rcMonitor.top, width, height,
                 SWP_FRAMECHANGED | SWP_SHOWWINDOW);
    resizeBuffers(width, height);
}

static void fullscreen(int width, int height) {
    DXGI_MODE_DESC mode = {0};
    mode.Width = width;
    mode.Height = height;
    mode.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    IDXGISwapChain_ResizeTarget(chain, &mode);
    IDXGISwapChain_SetFullscreenState(chain, TRUE, NULL);
    resizeBuffers(width, height);
}

static void ready(FILE *log, const char *go, const char *label, int index) {
    char path[MAX_PATH];
    describe(log, window, label, index);
    printf("ready %d\n", index);
    fflush(stdout);
    snprintf(path, sizeof(path), "%s%d", go, index);
    pump(0, path);
}

static int run(int argc, char **argv) {
    WNDCLASSW wc = {0};
    DXGI_SWAP_CHAIN_DESC desc = {0};
    RECT rect = {0, 0, 1920, 1080};
    FILE *log;
    if (argc < 4 || !(log = fopen(argv[2], "w"))) return 2;
    wc.lpfnWndProc = proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW);
    wc.lpszClassName = L"DisplayModeProbe";
    RegisterClassW(&wc);
    AdjustWindowRectEx(&rect, WS_OVERLAPPEDWINDOW, FALSE, 0);
    window = CreateWindowExW(0, wc.lpszClassName, L"Display mode probe", WS_OVERLAPPEDWINDOW, 100, 100,
                             rect.right - rect.left, rect.bottom - rect.top, NULL, NULL, wc.hInstance, NULL);
    desc.BufferCount = 2;
    desc.BufferDesc.Width = 1920;
    desc.BufferDesc.Height = 1080;
    desc.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.OutputWindow = window;
    desc.SampleDesc.Count = 1;
    desc.Windowed = TRUE;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    if (FAILED(D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION, &desc,
                                             &chain, &device, NULL, &context))) {
        fprintf(log, "{\"error\":\"device\"}\n");
        return 1;
    }
    {
        IDXGIFactory *factory = NULL;
        if (SUCCEEDED(IDXGISwapChain_GetParent(chain, &IID_IDXGIFactory, (void **)&factory))) {
            IDXGIFactory_MakeWindowAssociation(factory, window, DXGI_MWA_NO_ALT_ENTER);
            IDXGIFactory_Release(factory);
        }
    }
    makeTarget();
    ShowWindow(window, SW_SHOW);
    SetForegroundWindow(window);
    pump(1500, NULL);
    ready(log, argv[3], "start", 0);
    for (int i = 4; i < argc; i++) {
        int width = 0, height = 0;
        if (!strcmp(argv[i], "fullscreen")) fullscreen(1920, 1080);
        else if (!strcmp(argv[i], "borderless")) borderless();
        else if (!strcmp(argv[i], "maximize")) ShowWindow(window, SW_MAXIMIZE);
        else if (sscanf(argv[i], "windowed:%dx%d", &width, &height) == 2) windowed(width, height);
        else { fprintf(log, "{\"error\":\"step\",\"step\":\"%s\"}\n", argv[i]); return 2; }
        pump(200, NULL);
        ready(log, argv[3], argv[i], i - 3);
    }
    IDXGISwapChain_SetFullscreenState(chain, FALSE, NULL);
    return 0;
}

/* Visible top-level windows of the named executable, with a client area of at least 300x200. */
struct search { const char *exe; HWND found[16]; int count; };

static BOOL CALLBACK visit(HWND hwnd, LPARAM param) {
    struct search *search = (struct search *)param;
    DWORD pid = 0;
    HANDLE process;
    char name[MAX_PATH];
    DWORD size = sizeof(name);
    RECT client;
    if (!IsWindowVisible(hwnd) || search->count >= 16) return TRUE;
    GetWindowThreadProcessId(hwnd, &pid);
    if (!(process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid))) return TRUE;
    if (QueryFullProcessImageNameA(process, 0, name, &size)) {
        const char *base = strrchr(name, '\\');
        base = base ? base + 1 : name;
        if (!_stricmp(base, search->exe) && GetClientRect(hwnd, &client) && client.right >= 300 && client.bottom >= 200)
            search->found[search->count++] = hwnd;
    }
    CloseHandle(process);
    return TRUE;
}

static HWND only(const char *exe) {
    struct search search = {exe};
    EnumWindows(visit, (LPARAM)&search);
    if (search.count != 1) {
        fprintf(stderr, "%d visible windows of %s\n", search.count, exe);
        return NULL;
    }
    return search.found[0];
}

static BOOL front(HWND hwnd) {
    SetForegroundWindow(hwnd);
    for (int i = 0; i < 40 && GetForegroundWindow() != hwnd; i++) Sleep(50);
    return GetForegroundWindow() == hwnd;
}

static int send(INPUT *inputs, UINT count) {
    return SendInput(count, inputs, sizeof(INPUT)) == count ? 0 : 1;
}

int main(int argc, char **argv) {
    if (argc >= 2 && !strcmp(argv[1], "run")) return run(argc, argv);
    if (argc == 3 && !strcmp(argv[1], "inspect")) {
        struct search search = {argv[2]};
        EnumWindows(visit, (LPARAM)&search);
        for (int i = 0; i < search.count; i++) describe(stdout, search.found[i], argv[2], i);
        return search.count ? 0 : 1;
    }
    if (argc == 5 && !strcmp(argv[1], "click")) {
        HWND hwnd = only(argv[2]);
        POINT point = {atoi(argv[3]), atoi(argv[4])};
        INPUT inputs[2] = {{0}};
        if (!hwnd || !front(hwnd)) return 1;
        ClientToScreen(hwnd, &point);
        SetCursorPos(point.x, point.y);
        Sleep(100);
        inputs[0].type = inputs[1].type = INPUT_MOUSE;
        inputs[0].mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
        inputs[1].mi.dwFlags = MOUSEEVENTF_LEFTUP;
        if (send(inputs, 1)) return 1;
        Sleep(60);
        return send(inputs + 1, 1);
    }
    if (argc == 4 && !strcmp(argv[1], "key")) {
        HWND hwnd = only(argv[2]);
        INPUT inputs[16] = {{0}};
        WORD keys[8];
        int count = 0;
        for (char *part = strtok(argv[3], "+"); part && count < 8; part = strtok(NULL, "+"))
            keys[count++] = (WORD)strtoul(part, NULL, 16);
        if (!hwnd || !count || !front(hwnd)) return 1;
        for (int i = 0; i < count; i++) {
            inputs[i].type = INPUT_KEYBOARD;
            inputs[i].ki.wVk = keys[i];
            inputs[i].ki.wScan = (WORD)MapVirtualKeyW(keys[i], MAPVK_VK_TO_VSC);
            inputs[i].ki.dwFlags = KEYEVENTF_SCANCODE;
            inputs[2 * count - 1 - i] = inputs[i];
            inputs[2 * count - 1 - i].ki.dwFlags |= KEYEVENTF_KEYUP;
        }
        for (int i = 0; i < 2 * count; i++) {
            if (send(inputs + i, 1)) return 1;
            Sleep(40);
        }
        return 0;
    }
    return 2;
}
