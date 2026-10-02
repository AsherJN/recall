"""Run under the standalone Windows Python to test D3D11 without the game."""
import ctypes as c
import sys
import time
import uuid
import statistics

print("probe: before LoadLibrary(dxgi.dll)", flush=True)
dxgi = c.WinDLL("dxgi.dll")
print("probe: DXGI loaded", flush=True)
print("probe: before LoadLibrary(d3d11.dll)", flush=True)
dll = c.WinDLL("d3d11.dll")
print("probe: DLL loaded", flush=True)
create = dll.D3D11CreateDevice
create.argtypes = [c.c_void_p, c.c_uint, c.c_void_p, c.c_uint,
                   c.c_void_p, c.c_uint, c.c_uint,
                   c.POINTER(c.c_void_p), c.POINTER(c.c_uint), c.POINTER(c.c_void_p)]
create.restype = c.c_long
device, context, level = c.c_void_p(), c.c_void_p(), c.c_uint()
result = create(None, 1, None, 0, None, 0, 7,
                c.byref(device), c.byref(level), c.byref(context))
print(f"probe: device result=0x{result & 0xffffffff:08x} feature=0x{level.value:x}", flush=True)
if result >= 0 and "--swapchain" in sys.argv:
    class Rational(c.Structure):
        _fields_ = [("numerator", c.c_uint), ("denominator", c.c_uint)]
    class Mode(c.Structure):
        _fields_ = [("width", c.c_uint), ("height", c.c_uint), ("refresh", Rational),
                    ("format", c.c_uint), ("scanline", c.c_uint), ("scaling", c.c_uint)]
    class Samples(c.Structure):
        _fields_ = [("count", c.c_uint), ("quality", c.c_uint)]
    class SwapDesc(c.Structure):
        _fields_ = [("mode", Mode), ("samples", Samples), ("usage", c.c_uint),
                    ("buffers", c.c_uint), ("window", c.c_void_p), ("windowed", c.c_int),
                    ("effect", c.c_uint), ("flags", c.c_uint)]
    user = c.WinDLL("user32")
    user.CreateWindowExW.restype = c.c_void_p
    user.CreateWindowExW.argtypes = [c.c_uint, c.c_wchar_p, c.c_wchar_p, c.c_uint,
                                    c.c_int, c.c_int, c.c_int, c.c_int,
                                    c.c_void_p, c.c_void_p, c.c_void_p, c.c_void_p]
    hwnd = user.CreateWindowExW(0, "STATIC", "DXMT graphics diagnostic", 0x10cf0000,
                                20, 20, 640, 480, None, None, None, None)
    if not hwnd:
        raise c.WinError()
    desc = SwapDesc(Mode(640, 480, Rational(60, 1), 28, 0, 0), Samples(1, 0),
                    0x20, 2, hwnd, 1, 0, 0)
    create_swap = dll.D3D11CreateDeviceAndSwapChain
    create_swap.restype = c.c_long
    create_swap.argtypes = create.argtypes[:7] + [c.POINTER(SwapDesc), c.POINTER(c.c_void_p)] + create.argtypes[7:]
    swap, device2, context2, level2 = c.c_void_p(), c.c_void_p(), c.c_void_p(), c.c_uint()
    print("probe: before swapchain creation", flush=True)
    hr = create_swap(None, 1, None, 0, None, 0, 7, c.byref(desc), c.byref(swap),
                     c.byref(device2), c.byref(level2), c.byref(context2))
    print(f"probe: swapchain result=0x{hr & 0xffffffff:08x}", flush=True)
    if hr >= 0 and "--present" in sys.argv:
        def method(pointer, index, result_type, *arguments):
            table = c.cast(pointer, c.POINTER(c.POINTER(c.c_void_p))).contents
            return c.WINFUNCTYPE(result_type, c.c_void_p, *arguments)(table[index])
        iid = (c.c_ubyte * 16).from_buffer_copy(uuid.UUID("6f15aaf2-d208-4e89-9ab4-489535d34f9c").bytes_le)
        texture, target = c.c_void_p(), c.c_void_p()
        get_buffer = method(swap, 9, c.c_long, c.c_uint, c.c_void_p, c.POINTER(c.c_void_p))
        hr = get_buffer(swap, 0, c.byref(iid), c.byref(texture))
        if hr >= 0:
            create_target = method(device2, 9, c.c_long, c.c_void_p, c.c_void_p, c.POINTER(c.c_void_p))
            hr = create_target(device2, texture, None, c.byref(target))
        if hr >= 0:
            clear = method(context2, 50, None, c.c_void_p, c.POINTER(c.c_float))
            present = method(swap, 8, c.c_long, c.c_uint, c.c_uint)
            intervals = []
            start = time.perf_counter()
            for frame in range(120):
                color = (c.c_float * 4)(0.03, 0.05 + frame / 1200, 0.12, 1)
                clear(context2, target, color)
                hr = present(swap, 0, 0)
                now = time.perf_counter()
                intervals.append((now - start) * 1000)
                start = now
                if hr < 0:
                    break
            warm = sorted(intervals[10:])
            if warm:
                print(f"probe: {len(intervals)} presents; warm median={statistics.median(warm):.2f}ms "
                      f"p95={warm[int(.95 * (len(warm)-1))]:.2f}ms; not a game benchmark", flush=True)
        for pointer in [target, texture]:
            if pointer.value:
                method(pointer, 2, c.c_ulong)(pointer)
    for pointer in [swap, context2, device2]:
        if pointer.value:
            table = c.cast(pointer, c.POINTER(c.POINTER(c.c_void_p))).contents
            c.WINFUNCTYPE(c.c_ulong, c.c_void_p)(table[2])(pointer)
    user.DestroyWindow.argtypes = [c.c_void_p]
    user.DestroyWindow(hwnd)
    if hr < 0:
        result = hr
for pointer in [context, device]:
    if pointer.value:
        table = c.cast(pointer, c.POINTER(c.POINTER(c.c_void_p))).contents
        c.WINFUNCTYPE(c.c_ulong, c.c_void_p)(table[2])(pointer)
raise SystemExit(0 if result >= 0 else 1)
