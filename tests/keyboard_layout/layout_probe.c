/* Recall #46: a keyboard layout chosen in macOS while a program runs reaches the program. Before
 * the fix the Mac driver followed a new input source only when the window's input context was
 * macOS's current one, which in Overwatch it often is not, so the game typed with the layout it
 * started with until it was restarted.
 *
 *   layout_probe.exe SECONDS
 *
 * Opens a small window, brings it to the front and prints {"ready": true}, then every 100 ms for
 * SECONDS one JSON line: the thread's keyboard layout and the character the Q key types (scan code
 * 0x10 through MapVirtualKey and ToUnicodeEx, as TranslateMessage makes WM_CHAR), and a line for
 * each WM_INPUTLANGCHANGE. */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

static DWORD start_ms, seconds;

static void sample( void )
{
    BYTE state[256] = {0};
    WCHAR text[8];
    UINT vk = MapVirtualKeyW( 0x10, MAPVK_VSC_TO_VK );
    HKL hkl = GetKeyboardLayout( 0 );
    int count = ToUnicodeEx( vk, 0x10, state, text, 8, 0, hkl );

    printf( "{\"ms\": %lu, \"hkl\": \"%p\", \"vk\": %u, \"q\": %d}\n", GetTickCount() - start_ms, (void *)hkl, vk,
            count == 1 ? text[0] : -1 );
    fflush( stdout );
}

static LRESULT CALLBACK window_proc( HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam )
{
    switch (msg)
    {
    case WM_INPUTLANGCHANGE:
        printf( "{\"ms\": %lu, \"inputlangchange\": \"%p\"}\n", GetTickCount() - start_ms, (void *)lparam );
        fflush( stdout );
        break;
    case WM_TIMER:
        sample();
        if (GetTickCount() - start_ms >= seconds * 1000) DestroyWindow( hwnd );
        return 0;
    case WM_DESTROY:
        PostQuitMessage( 0 );
        return 0;
    }
    return DefWindowProcW( hwnd, msg, wparam, lparam );
}

int main( int argc, char **argv )
{
    WNDCLASSW cls = {0};
    HWND hwnd;
    MSG msg;

    seconds = argc > 1 ? atoi( argv[1] ) : 10;
    cls.lpfnWndProc = window_proc;
    cls.hInstance = GetModuleHandleW( NULL );
    cls.lpszClassName = L"RecallLayoutProbe";
    RegisterClassW( &cls );
    hwnd = CreateWindowExW( 0, cls.lpszClassName, L"Recall layout probe", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                            100, 100, 320, 120, NULL, NULL, cls.hInstance, NULL );
    if (!hwnd) return 1;
    SetForegroundWindow( hwnd );
    start_ms = GetTickCount();
    printf( "{\"ready\": true, \"foreground\": %s}\n", GetForegroundWindow() == hwnd ? "true" : "false" );
    fflush( stdout );
    sample();
    SetTimer( hwnd, 1, 100, NULL );
    while (GetMessageW( &msg, NULL, 0, 0 ) > 0)
    {
        TranslateMessage( &msg );
        DispatchMessageW( &msg );
    }
    return 0;
}
