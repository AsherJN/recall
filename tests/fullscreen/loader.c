/* Minimal Winelib entry for the owned native fixture; no CRT state. */
#include <windef.h>
BOOL WINAPI __wine_spec_dll_entry(HINSTANCE instance, DWORD reason, void *reserved)
{
    (void)instance; (void)reason; (void)reserved;
    return TRUE;
}
