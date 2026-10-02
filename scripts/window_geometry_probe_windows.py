"""Inspect only a diagnostic-owned window's sizing under Windows Python/Wine.

No lookup, messages, handles or modifications target another application's window.
"""
import argparse
import ctypes as c
import json
import time
import uuid

UINT = c.c_uint
INT = c.c_int
PTR = c.c_void_p
LONG = c.c_long


class Rect(c.Structure):
    _fields_ = [(name, LONG) for name in ("left", "top", "right", "bottom")]


class Point(c.Structure):
    _fields_ = [("x", LONG), ("y", LONG)]


class Message(c.Structure):
    _fields_ = [("window", PTR), ("message", UINT), ("wparam", c.c_size_t),
                ("lparam", c.c_ssize_t), ("time", UINT), ("point", Point)]


class MonitorInfo(c.Structure):
    _fields_ = [("size", UINT), ("monitor", Rect), ("work", Rect), ("flags", UINT)]


class Rational(c.Structure):
    _fields_ = [("numerator", UINT), ("denominator", UINT)]


class Mode(c.Structure):
    _fields_ = [("width", UINT), ("height", UINT), ("refresh", Rational),
                ("format", UINT), ("scanline", UINT), ("scaling", UINT)]


class Samples(c.Structure):
    _fields_ = [("count", UINT), ("quality", UINT)]


class SwapDesc(c.Structure):
    _fields_ = [("mode", Mode), ("samples", Samples), ("usage", UINT),
                ("buffers", UINT), ("window", PTR), ("windowed", INT),
                ("effect", UINT), ("flags", UINT)]


def method(pointer, index, result_type, *args):
    table = c.cast(pointer, c.POINTER(c.POINTER(PTR))).contents
    return c.WINFUNCTYPE(result_type, PTR, *args)(table[index])


def values(rect):
    return [rect.left, rect.top, rect.right, rect.bottom]


def run(width, height, dpi_mode, maximize):
    user = c.WinDLL("user32", use_last_error=True)
    bindings = {
        "SetProcessDpiAwarenessContext": (INT, [PTR]),
        "GetDpiForSystem": (UINT, []), "GetDpiForWindow": (UINT, [PTR]),
        "GetSystemMetrics": (INT, [INT]),
        "AdjustWindowRectExForDpi": (INT, [c.POINTER(Rect), UINT, INT, UINT, UINT]),
        "CreateWindowExW": (PTR, [UINT, c.c_wchar_p, c.c_wchar_p, UINT,
                                 INT, INT, INT, INT, PTR, PTR, PTR, PTR]),
        "DestroyWindow": (INT, [PTR]),
        "GetClientRect": (INT, [PTR, c.POINTER(Rect)]),
        "GetWindowRect": (INT, [PTR, c.POINTER(Rect)]),
        "GetWindowLongW": (LONG, [PTR, INT]), "IsZoomed": (INT, [PTR]),
        "MonitorFromWindow": (PTR, [PTR, UINT]),
        "GetMonitorInfoW": (INT, [PTR, c.POINTER(MonitorInfo)]),
        "PeekMessageW": (INT, [c.POINTER(Message), PTR, UINT, UINT, UINT]),
        "TranslateMessage": (INT, [c.POINTER(Message)]),
        "DispatchMessageW": (c.c_ssize_t, [c.POINTER(Message)]),
        "ShowWindow": (INT, [PTR, INT]),
    }
    for name, (restype, argtypes) in bindings.items():
        fn = getattr(user, name)
        fn.restype, fn.argtypes = restype, argtypes
    aware = user.SetProcessDpiAwarenessContext({"unaware": -1, "system": -2, "permonitor": -4}[dpi_mode])
    dpi = user.GetDpiForSystem()
    print(json.dumps(dict(phase="before_window", dpi_mode=dpi_mode, awareness_set=bool(aware),
                          system_dpi=dpi, screen=[user.GetSystemMetrics(0), user.GetSystemMetrics(1)],
                          requested_client=[width, height])), flush=True)
    window = None
    owned = []

    def pump(seconds=0.5):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            message = Message()
            for _ in range(256):
                if not user.PeekMessageW(c.byref(message), window, 0, 0, 1):
                    break
                if message.message == 0x0010:
                    raise RuntimeError("Diagnostic window was closed during the probe")
                user.TranslateMessage(c.byref(message))
                user.DispatchMessageW(c.byref(message))
            time.sleep(0.01)

    def snapshot(phase):
        client, outer = Rect(), Rect()
        if not user.GetClientRect(window, c.byref(client)) or not user.GetWindowRect(window, c.byref(outer)):
            raise c.WinError(c.get_last_error())
        monitor = MonitorInfo()
        monitor.size = c.sizeof(monitor)
        if not user.GetMonitorInfoW(user.MonitorFromWindow(window, 2), c.byref(monitor)):
            raise c.WinError(c.get_last_error())
        record = dict(phase=phase, client_rect=values(client), window_rect=values(outer),
                      client_size=[client.right-client.left, client.bottom-client.top],
                      window_dpi=user.GetDpiForWindow(window), maximized=bool(user.IsZoomed(window)),
                      style=hex(user.GetWindowLongW(window, -16) & 0xffffffff),
                      monitor_rect=values(monitor.monitor), work_rect=values(monitor.work))
        print(json.dumps(record), flush=True)
        return record

    try:
        style = 0x10CF0000  # WS_VISIBLE | WS_OVERLAPPEDWINDOW
        rect = Rect(0, 0, width, height)
        if not user.AdjustWindowRectExForDpi(c.byref(rect), style, 0, 0, dpi):
            raise c.WinError(c.get_last_error())
        window = user.CreateWindowExW(0, "STATIC", "DXMT owned-window size diagnostic", style,
                                      100, 100, rect.right-rect.left, rect.bottom-rect.top,
                                      None, None, None, None)
        if not window:
            raise c.WinError(c.get_last_error())
        snapshot("created")
        pump()
        measured = snapshot("after_initial_pump")
        d3d11 = c.WinDLL("d3d11.dll")
        create = d3d11.D3D11CreateDeviceAndSwapChain
        create.restype = LONG
        create.argtypes = [PTR, UINT, PTR, UINT, PTR, UINT, UINT,
                           c.POINTER(SwapDesc), c.POINTER(PTR), c.POINTER(PTR),
                           c.POINTER(UINT), c.POINTER(PTR)]
        device, context, swap, level = PTR(), PTR(), PTR(), UINT()
        owned.extend([device, context, swap])
        actual_width, actual_height = measured["client_size"]
        desc = SwapDesc(Mode(actual_width, actual_height, Rational(60, 1), 28, 0, 0),
                        Samples(1, 0), 0x20, 2, window, 1, 0, 0)
        result = create(None, 1, None, 0, None, 0, 7, c.byref(desc), c.byref(swap),
                        c.byref(device), c.byref(level), c.byref(context))
        if result < 0:
            raise RuntimeError(f"CreateDeviceAndSwapChain failed: {result & 0xffffffff:08x}")
        texture, target = PTR(), PTR()
        owned.extend([texture, target])
        texture_iid = (c.c_ubyte * 16).from_buffer_copy(
            uuid.UUID("6f15aaf2-d208-4e89-9ab4-489535d34f9c").bytes_le)
        result = method(swap, 9, LONG, UINT, PTR, c.POINTER(PTR))(
            swap, 0, c.byref(texture_iid), c.byref(texture))
        if result < 0:
            raise RuntimeError("Cannot acquire diagnostic backbuffer")
        result = method(device, 9, LONG, PTR, PTR, c.POINTER(PTR))(
            device, texture, None, c.byref(target))
        if result < 0:
            raise RuntimeError("Cannot create diagnostic render target")
        pump()
        snapshot("after_dxmt_creation")
        current = SwapDesc()
        result = method(swap, 12, LONG, c.POINTER(SwapDesc))(swap, c.byref(current))
        print(json.dumps(dict(phase="swapchain", result=result,
                              backbuffer=[current.mode.width, current.mode.height],
                              windowed=bool(current.windowed))), flush=True)
        # Present-owned backbuffer only; it contains no private application data.
        for _ in range(3):
            color = (c.c_float * 4)(0.03, 0.07, 0.12, 1.0)
            method(context, 50, None, PTR, c.POINTER(c.c_float))(context, target, color)
            result = method(swap, 8, LONG, UINT, UINT)(swap, 0, 0)
            if result < 0:
                raise RuntimeError(f"Present failed: {result & 0xffffffff:08x}")
            pump(0.1)
        snapshot("after_present")
        if maximize:
            user.ShowWindow(window, 3)  # Maximize only the window created above.
            pump()
            snapshot("owned_window_maximized")
            user.ShowWindow(window, 9)  # Restore only that owned window.
            pump()
            snapshot("owned_window_restored")
        print(json.dumps(dict(result="PASS", requested_client=[width, height])), flush=True)
    finally:
        for pointer in reversed(owned):
            if pointer.value:
                method(pointer, 2, c.c_ulong)(pointer)
        if window:
            user.DestroyWindow(window)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--width", type=int, default=1920)
    parser.add_argument("--height", type=int, default=1080)
    parser.add_argument("--dpi", choices=("unaware", "system", "permonitor"), default="permonitor")
    parser.add_argument("--maximize", action="store_true")
    args = parser.parse_args()
    if not 64 <= args.width <= 3840 or not 64 <= args.height <= 2160:
        parser.error("Diagnostic dimensions must be between 64×64 and 3840×2160.")
    try:
        run(args.width, args.height, args.dpi, args.maximize)
    except Exception as error:
        print(json.dumps(dict(result="FAIL", error=str(error)[:1200])), flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
