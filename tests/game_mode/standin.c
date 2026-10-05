/* Windows stand-in for Overwatch when testing macOS Game Mode under Recall's engine
 * (tests/game_mode/play.py --stand-in): a Direct3D 11 window that asks DXGI for
 * fullscreen as the game does and keeps the GPU busy. play.py builds it as
 * Overwatch.exe, so the engine applies the game's renderer profile (the fullscreen
 * canvas) and Wine names its loader link as it would for the game.
 * Usage: Overwatch.exe <seconds> */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdlib.h>

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam)
{
    if (message == WM_DESTROY)
    {
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, PWSTR command, int show)
{
    DWORD seconds = command && *command ? (DWORD)_wtoi(command) : 60, start;
    WNDCLASSW window_class = {.lpfnWndProc = window_proc, .hInstance = instance,
                              .lpszClassName = L"GameModeStandIn", .hCursor = LoadCursorW(NULL, IDC_ARROW)};
    RECT rect = {0, 0, 1920, 1080};
    DXGI_SWAP_CHAIN_DESC desc = {
        .BufferDesc = {.Width = 1920, .Height = 1080, .Format = DXGI_FORMAT_R8G8B8A8_UNORM},
        .SampleDesc = {.Count = 1}, .BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT, .BufferCount = 2,
        .Windowed = TRUE, .SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD, .Flags = DXGI_SWAP_CHAIN_FLAG_ALLOW_MODE_SWITCH};
    /* A large offscreen target cleared repeatedly every frame keeps the GPU busy. */
    D3D11_TEXTURE2D_DESC load_desc = {.Width = 4096, .Height = 4096, .MipLevels = 1, .ArraySize = 1,
                                      .Format = DXGI_FORMAT_R16G16B16A16_FLOAT, .SampleDesc = {.Count = 1},
                                      .BindFlags = D3D11_BIND_RENDER_TARGET};
    IDXGISwapChain *swapchain;
    ID3D11Device *device;
    ID3D11DeviceContext *context;
    ID3D11Texture2D *load_texture;
    ID3D11RenderTargetView *load_view;
    BOOL running = TRUE;
    MSG message;
    HWND window;

    RegisterClassW(&window_class);
    AdjustWindowRect(&rect, WS_OVERLAPPEDWINDOW, FALSE);
    window = CreateWindowW(L"GameModeStandIn", L"Game Mode stand-in", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                           CW_USEDEFAULT, CW_USEDEFAULT, rect.right - rect.left, rect.bottom - rect.top,
                           NULL, NULL, instance, NULL);
    desc.OutputWindow = window;
    if (FAILED(D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION,
                                             &desc, &swapchain, &device, NULL, &context)))
        return 1;
    if (FAILED(ID3D11Device_CreateTexture2D(device, &load_desc, NULL, &load_texture)) ||
        FAILED(ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)load_texture, NULL, &load_view)))
        return 2;
    IDXGISwapChain_SetFullscreenState(swapchain, TRUE, NULL);

    start = GetTickCount();
    while (running && GetTickCount() - start < seconds * 1000)
    {
        ID3D11Texture2D *back;
        ID3D11RenderTargetView *view;
        float t = (GetTickCount() - start) / 1000.0f, color[4] = {t - (int)t, 0.3f, 0.6f, 1.0f};
        int i;

        while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE))
        {
            if (message.message == WM_QUIT) running = FALSE;
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        if (FAILED(IDXGISwapChain_GetBuffer(swapchain, 0, &IID_ID3D11Texture2D, (void **)&back))) break;
        ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)back, NULL, &view);
        for (i = 0; i < 8; i++)
        {
            float load[4] = {i / 8.0f, color[0], 0.5f, 1.0f};
            ID3D11DeviceContext_ClearRenderTargetView(context, load_view, load);
        }
        ID3D11DeviceContext_ClearRenderTargetView(context, view, color);
        IDXGISwapChain_Present(swapchain, 0, 0);
        ID3D11RenderTargetView_Release(view);
        ID3D11Texture2D_Release(back);
    }
    IDXGISwapChain_SetFullscreenState(swapchain, FALSE, NULL);
    return 0;
}
