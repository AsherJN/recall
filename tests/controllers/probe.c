/* Controllers as a Windows game sees them through Wine: every HID game controller
 * (its device path carries the VID/PID and, for an XInput pad, "IG_") and the four
 * XInput slots. With a number of seconds, prints each XInput state change meanwhile.
 * Built by tests/controllers/run.py with the pinned LLVM-MinGW. */
#include <windows.h>
#include <setupapi.h>
#include <hidsdi.h>
#include <xinput.h>
#include <stdio.h>
#include <stdlib.h>

static void list_hid(void)
{
    HDEVINFO set;
    SP_DEVICE_INTERFACE_DATA iface = {sizeof(iface)};
    GUID guid;
    DWORD i;

    HidD_GetHidGuid(&guid);
    set = SetupDiGetClassDevsW(&guid, NULL, NULL, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    for (i = 0; SetupDiEnumDeviceInterfaces(set, NULL, &guid, i, &iface); i++)
    {
        char buffer[1024];
        SP_DEVICE_INTERFACE_DETAIL_DATA_A *detail = (void *)buffer;
        HIDD_ATTRIBUTES attributes = {sizeof(attributes)};
        PHIDP_PREPARSED_DATA preparsed;
        HIDP_CAPS caps = {0};
        WCHAR product[128] = L"";
        HANDLE device;

        detail->cbSize = sizeof(*detail);
        if (!SetupDiGetDeviceInterfaceDetailA(set, &iface, detail, sizeof(buffer), NULL, NULL)) continue;
        device = CreateFileA(detail->DevicePath, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
        if (device == INVALID_HANDLE_VALUE) continue;
        HidD_GetAttributes(device, &attributes);
        HidD_GetProductString(device, product, sizeof(product));
        if (HidD_GetPreparsedData(device, &preparsed))
        {
            HidP_GetCaps(preparsed, &caps);
            HidD_FreePreparsedData(preparsed);
        }
        CloseHandle(device);
        /* Generic desktop joysticks and gamepads only: Wine also lists its keyboard and mouse. */
        if (caps.UsagePage != 1 || (caps.Usage != 4 && caps.Usage != 5)) continue;
        printf("hid %04x:%04x usage %x:%x \"%ls\" %s\n", attributes.VendorID, attributes.ProductID,
               caps.UsagePage, caps.Usage, product, detail->DevicePath);
    }
    SetupDiDestroyDeviceInfoList(set);
}

int main(int argc, char **argv)
{
    XINPUT_STATE last[XUSER_MAX_COUNT] = {0};
    DWORD seconds = argc > 1 ? atoi(argv[1]) : 0, start, slot;

    list_hid();
    for (slot = 0; slot < XUSER_MAX_COUNT; slot++)
    {
        XINPUT_CAPABILITIES caps;
        DWORD result = XInputGetCapabilities(slot, 0, &caps);
        if (result == ERROR_DEVICE_NOT_CONNECTED) printf("xinput %lu: not connected\n", slot);
        else printf("xinput %lu: connected, type %u subtype %u, result %lu\n", slot, caps.Type, caps.SubType, result);
        XInputGetState(slot, &last[slot]);
    }
    fflush(stdout);
    for (start = GetTickCount(); GetTickCount() - start < seconds * 1000; Sleep(10))
    {
        for (slot = 0; slot < XUSER_MAX_COUNT; slot++)
        {
            XINPUT_STATE state;
            if (XInputGetState(slot, &state) != ERROR_SUCCESS || state.dwPacketNumber == last[slot].dwPacketNumber) continue;
            printf("xinput %lu: buttons %04x lt %3u rt %3u lx %6d ly %6d rx %6d ry %6d\n", slot,
                   state.Gamepad.wButtons, state.Gamepad.bLeftTrigger, state.Gamepad.bRightTrigger,
                   state.Gamepad.sThumbLX, state.Gamepad.sThumbLY, state.Gamepad.sThumbRX, state.Gamepad.sThumbRY);
            fflush(stdout);
            last[slot] = state;
        }
    }
    return 0;
}
