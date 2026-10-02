"""Standalone D3D11 shader/draw/readback diagnostic for Windows Python in Wine.

Creates only its own window and D3D11 objects; never attaches to a game.
Identical options compile the same HLSL, so isolated cold/warm translator-cache
runs are comparable. Pixel readback checks geometry, interpolation, shader
execution, and resource synchronization. Timing is NOT a game benchmark.

COM slots and structures follow the installed Wine headers:
  include/wine/windows/{d3d11.h,dxgi.h,d3dcompiler.h}
Default: 12 presents. Use --frames 120 for a longer pacing smoke test.
"""

import argparse
import ctypes as c
import json
from pathlib import Path
import sys
import time
import uuid


UINT = c.c_uint32
INT = c.c_int32
HRESULT = c.c_int32
PTR = c.c_void_p
FLOAT = c.c_float


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


class TextureDesc(c.Structure):
    _fields_ = [("width", UINT), ("height", UINT), ("mip_levels", UINT),
                ("array_size", UINT), ("format", UINT), ("samples", Samples),
                ("usage", UINT), ("bind_flags", UINT), ("cpu_access_flags", UINT),
                ("misc_flags", UINT)]


class RasterizerDesc(c.Structure):
    _fields_ = [("fill", UINT), ("cull", UINT), ("front_ccw", INT),
                ("depth_bias", INT), ("depth_bias_clamp", FLOAT),
                ("slope_scaled_depth_bias", FLOAT), ("depth_clip", INT),
                ("scissor", INT), ("multisample", INT), ("antialiased_line", INT)]


class Viewport(c.Structure):
    _fields_ = [("x", FLOAT), ("y", FLOAT), ("width", FLOAT), ("height", FLOAT),
                ("min_depth", FLOAT), ("max_depth", FLOAT)]


class Mapped(c.Structure):
    _fields_ = [("data", PTR), ("row_pitch", UINT), ("depth_pitch", UINT)]


class Rect(c.Structure):
    _fields_ = [("left", INT), ("top", INT), ("right", INT), ("bottom", INT)]


class Point(c.Structure):
    _fields_ = [("x", INT), ("y", INT)]


class Message(c.Structure):
    _fields_ = [("window", PTR), ("message", UINT), ("wparam", c.c_size_t),
                ("lparam", c.c_ssize_t), ("time", UINT), ("point", Point),
                ("private", UINT)]


HLSL = b"""
struct VertexOutput {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
};
VertexOutput VSMain(uint id : SV_VertexID) {
    VertexOutput output;
    float2 uv = float2((id << 1) & 2, id & 2);
    output.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    output.uv = uv;
    return output;
}
float4 PSMain(VertexOutput input) : SV_Target {
    return float4(input.uv, 0.25, 1.0);
}
"""


def method(pointer, slot, result_type, *argument_types):
    table = c.cast(pointer, c.POINTER(c.POINTER(PTR))).contents
    return c.WINFUNCTYPE(result_type, PTR, *argument_types)(table[slot])


def check(result, operation):
    if result < 0:
        raise RuntimeError(f"{operation}: HRESULT 0x{result & 0xffffffff:08x}")


def release(pointer):
    if pointer.value:
        method(pointer, 2, UINT)(pointer)
        pointer.value = None


def compile_shader(compiler, entrypoint, profile, blue=64):
    compile_hlsl = compiler.D3DCompile
    compile_hlsl.restype = HRESULT
    compile_hlsl.argtypes = [PTR, c.c_size_t, c.c_char_p, PTR, PTR, c.c_char_p,
                            c.c_char_p, UINT, UINT, c.POINTER(PTR), c.POINTER(PTR)]
    shader_source = HLSL if blue == 64 else HLSL.replace(b"0.25", f"({blue}.0 / 255.0)".encode())
    source = c.create_string_buffer(shader_source)
    blob, errors = PTR(), PTR()
    try:
        hr = compile_hlsl(source, len(shader_source), b"dxmt_render_probe.hlsl", None, None,
                          entrypoint, profile, 1 << 11, 0, c.byref(blob), c.byref(errors))
        if hr < 0:
            detail = ""
            if errors.value:
                data = method(errors, 3, PTR)(errors)
                size = method(errors, 4, c.c_size_t)(errors)
                detail = c.string_at(data, min(size, 2048)).decode("utf-8", errors="replace").rstrip("\0")
            raise RuntimeError(f"D3DCompile({profile.decode()}): 0x{hr & 0xffffffff:08x}; {detail}")
        if not blob.value:
            raise RuntimeError("D3DCompile returned no bytecode")
        data = method(blob, 3, PTR)(blob)
        size = method(blob, 4, c.c_size_t)(blob)
        return c.string_at(data, size)
    finally:
        release(errors)
        release(blob)


def run(frames, width=320, height=180, blue=64, waitable=False, canvas_probe=None, gpu_draws=1):
    if sys.platform != "win32" or c.sizeof(PTR) != 8:
        raise RuntimeError("Run this script with the isolated 64-bit Windows Python under Wine")
    # Detect ABI mistakes before any foreign function call.
    for structure, expected_size in [(SwapDesc, 72), (TextureDesc, 44),
                                      (RasterizerDesc, 40), (Viewport, 24),
                                      (Mapped, 16), (Message, 48)]:
        if c.sizeof(structure) != expected_size:
            raise RuntimeError(f"Unexpected ABI size for {structure.__name__}")

    user = c.WinDLL("user32", use_last_error=True)
    user.SetProcessDPIAware.argtypes = []
    user.SetProcessDPIAware.restype = INT
    user.SetProcessDPIAware()
    user.AdjustWindowRectEx.argtypes = [c.POINTER(Rect), UINT, INT, UINT]
    user.AdjustWindowRectEx.restype = INT
    user.CreateWindowExW.argtypes = [UINT, c.c_wchar_p, c.c_wchar_p, UINT,
                                    INT, INT, INT, INT, PTR, PTR, PTR, PTR]
    user.CreateWindowExW.restype = PTR
    user.DestroyWindow.argtypes = [PTR]
    user.DestroyWindow.restype = INT
    user.PeekMessageW.argtypes = [c.POINTER(Message), PTR, UINT, UINT, UINT]
    user.PeekMessageW.restype = INT
    user.TranslateMessage.argtypes = [c.POINTER(Message)]
    user.TranslateMessage.restype = INT
    user.DispatchMessageW.argtypes = [c.POINTER(Message)]
    user.DispatchMessageW.restype = c.c_ssize_t
    user.GetClientRect.argtypes = [PTR, c.POINTER(Rect)]
    user.ClientToScreen.argtypes = [PTR, c.POINTER(Point)]
    user.GetCursorPos.argtypes = [c.POINTER(Point)]
    user.SetCursorPos.argtypes = [INT, INT]

    seen_clicks = 0
    def pump(window):
        nonlocal seen_clicks
        message = Message()
        for _ in range(64):
            if not user.PeekMessageW(c.byref(message), window, 0, 0, 1):
                break
            if message.message == 0x0010:  # WM_CLOSE, only this diagnostic window.
                raise RuntimeError("Diagnostic window closed before completion")
            if canvas_probe and message.message in (0x0201,0x0203):
                seen_clicks += 1
                with canvas_probe.with_name('mouse.jsonl').open('a') as stream:
                    stream.write(json.dumps(dict(unix_s=time.time(),x=c.c_int16(message.lparam & 65535).value,
                                                 y=c.c_int16((message.lparam>>16)&65535).value))+'\n')
            user.TranslateMessage(c.byref(message))
            user.DispatchMessageW(c.byref(message))

    owned = []
    window = None
    context = PTR()
    try:
        compiler = c.WinDLL("d3dcompiler_47.dll")
        vertex_code = compile_shader(compiler, b"VSMain", b"vs_5_0", blue)
        pixel_code = compile_shader(compiler, b"PSMain", b"ps_5_0", blue)
        print(json.dumps({"phase": "hlsl_compiled", "vertex_bytes": len(vertex_code),
                          "pixel_bytes": len(pixel_code)}), flush=True)

        style = 0x10CF0000  # WS_VISIBLE | WS_OVERLAPPEDWINDOW
        if canvas_probe:
            style |= 0x100  # SS_NOTIFY: STATIC must accept hit testing for input checks.
        rect = Rect(0, 0, width, height)
        if not user.AdjustWindowRectEx(c.byref(rect), style, 0, 0):
            raise c.WinError(c.get_last_error())
        window = user.CreateWindowExW(0, "STATIC", "DXMT shader render diagnostic", style,
                                      40, 40, rect.right - rect.left, rect.bottom - rect.top,
                                      None, None, None, None)
        if not window:
            raise c.WinError(c.get_last_error())
        pump(window)

        d3d11 = c.WinDLL("d3d11.dll")
        create = d3d11.D3D11CreateDeviceAndSwapChain
        create.restype = HRESULT
        create.argtypes = [PTR, UINT, PTR, UINT, PTR, UINT, UINT,
                           c.POINTER(SwapDesc), c.POINTER(PTR), c.POINTER(PTR),
                           c.POINTER(UINT), c.POINTER(PTR)]
        desc = SwapDesc(Mode(width, height, Rational(60, 1), 28, 0, 0), Samples(1, 0),
                        0x20, 2, window, 1, 3 if waitable else 0, 0x40 if waitable else 0)
        device, swapchain, level = PTR(), PTR(), UINT()
        # Register outputs before checking HRESULT so partial failures clean up.
        owned.extend([device, context, swapchain])
        check(create(None, 1, None, 0, None, 0, 7, c.byref(desc), c.byref(swapchain),
                     c.byref(device), c.byref(level), c.byref(context)), "CreateDeviceAndSwapChain")

        if canvas_probe:
            dxgi_device=PTR()
            iid=(c.c_ubyte*16).from_buffer_copy(uuid.UUID("77db970f-6276-48ba-ba28-070143b4392c").bytes_le)
            check(method(device,0,HRESULT,PTR,c.POINTER(PTR))(device,c.byref(iid),c.byref(dxgi_device)), 'IDXGIDevice1')
            owned.append(dxgi_device)
            for requested in (0,3,1):
                check(method(dxgi_device,12,HRESULT,UINT)(dxgi_device,requested),'SetMaximumFrameLatency')
                effective=UINT()
                check(method(dxgi_device,13,HRESULT,c.POINTER(UINT))(dxgi_device,c.byref(effective)), 'GetMaximumFrameLatency')
                assert effective.value==1,effective.value
            assert method(dxgi_device,12,HRESULT,UINT)(dxgi_device,17)<0

        texture, target, vertex, pixel, rasterizer, staging = (PTR() for _ in range(6))
        owned.extend([texture, target, vertex, pixel, rasterizer, staging])
        texture_iid = (c.c_ubyte * 16).from_buffer_copy(
            uuid.UUID("6f15aaf2-d208-4e89-9ab4-489535d34f9c").bytes_le)
        check(method(swapchain, 9, HRESULT, UINT, PTR, c.POINTER(PTR))(
            swapchain, 0, c.byref(texture_iid), c.byref(texture)), "GetBuffer")
        check(method(device, 9, HRESULT, PTR, PTR, c.POINTER(PTR))(
            device, texture, None, c.byref(target)), "CreateRenderTargetView")
        for slot, code, shader, label in [(12, vertex_code, vertex, "Vertex"),
                                            (15, pixel_code, pixel, "Pixel")]:
            code_buffer = c.create_string_buffer(code)
            check(method(device, slot, HRESULT, PTR, c.c_size_t, PTR, c.POINTER(PTR))(
                device, code_buffer, len(code), None, c.byref(shader)), f"Create{label}Shader")

        raster_desc = RasterizerDesc(3, 1, 0, 0, 0, 0, 1, 0, 0, 0)
        check(method(device, 22, HRESULT, c.POINTER(RasterizerDesc), c.POINTER(PTR))(
            device, c.byref(raster_desc), c.byref(rasterizer)), "CreateRasterizerState")
        staging_desc = TextureDesc(width, height, 1, 1, 28, Samples(1, 0), 3, 0, 0x20000, 0)
        check(method(device, 5, HRESULT, c.POINTER(TextureDesc), PTR, c.POINTER(PTR))(
            device, c.byref(staging_desc), None, c.byref(staging)), "CreateStagingTexture")

        targets = (PTR * 1)(target.value)
        method(context, 33, None, UINT, c.POINTER(PTR), PTR)(context, 1, targets, None)
        method(context, 11, None, PTR, PTR, UINT)(context, vertex, None, 0)
        method(context, 9, None, PTR, PTR, UINT)(context, pixel, None, 0)
        method(context, 24, None, UINT)(context, 4)  # Triangle list.
        method(context, 43, None, PTR)(context, rasterizer)
        viewport = Viewport(0, 0, width, height, 0, 1)
        method(context, 44, None, UINT, c.POINTER(Viewport))(context, 1, c.byref(viewport))
        clear = method(context, 50, None, PTR, c.POINTER(FLOAT))
        draw = method(context, 13, None, UINT, UINT)
        present = method(swapchain, 8, HRESULT, UINT, UINT)
        clear_color = (FLOAT * 4)(0.9, 0.0, 0.9, 1.0)
        pixel_results = []
        # Establish the v2 logger baseline before the first draw requests shader
        # variants, so the cold/warm compile-start delta is observable.
        clear(context, target, clear_color)
        check(present(swapchain, 0, 0), "BaselinePresent")
        started = time.perf_counter()

        for frame in range(frames):
            pump(window)
            if canvas_probe: time.sleep(.002)
            if canvas_probe and (frame % 60 == 0 or canvas_probe.with_suffix('.command').exists()):
                actual = Rect()
                assert user.GetClientRect(window, c.byref(actual))
                swap_desc = SwapDesc()
                check(method(swapchain, 12, HRESULT, c.POINTER(SwapDesc))(
                    swapchain, c.byref(swap_desc)), 'GetDesc')
                record = dict(frame=frame, unix_s=time.time(),
                              client=[actual.right, actual.bottom],
                              swapchain=[swap_desc.mode.width, swap_desc.mode.height])
                command = canvas_probe.with_suffix('.command')
                if command.exists():
                    action = command.read_text().strip()
                    if action.startswith('cursor:') and seen_clicks < int(action.split(':')[1]):
                        continue  # Drain clicks before a cursor warp can rewrite queued positions.
                    command.unlink()
                    if action == 'cursor' or action.startswith('cursor:'):
                        positions = []
                        for x,y in [(16,16),(width//2,height//2),(width-16,height-16)]:
                            wanted = Point(x,y)
                            assert user.ClientToScreen(window,c.byref(wanted))
                            assert user.SetCursorPos(wanted.x,wanted.y)
                            time.sleep(.02)
                            found = Point()
                            assert user.GetCursorPos(c.byref(found))
                            positions.append(dict(wanted=[wanted.x,wanted.y], found=[found.x,found.y]))
                        record['cursor_roundtrip'] = positions
                    elif action in ('fullscreen_on','fullscreen_off'):
                        on=action == 'fullscreen_on'
                        # Exercise the real DXGI API and borderless game styles,
                        # not a native toggle performed by the test helper.
                        user.SetWindowLongW.argtypes=[PTR,INT,INT]
                        user.SetWindowLongW.restype=INT
                        if on:
                            user.SetWindowLongW(window,-16,c.c_int32(style & ~0x00cf0000).value)
                            mode=Mode(width,height,Rational(120,1),28,0,0)
                            check(method(swapchain,14,HRESULT,c.POINTER(Mode))(swapchain,c.byref(mode)),'ResizeTarget')
                        check(method(swapchain,10,HRESULT,INT,PTR)(swapchain,int(on),None),'SetFullscreenState')
                        if not on:user.SetWindowLongW(window,-16,c.c_int32(style).value)
                        fs=INT()
                        check(method(swapchain,11,HRESULT,c.POINTER(INT),PTR)(swapchain,c.byref(fs),None),'GetFullscreenState')
                        assert bool(fs.value)==on,(action,fs.value)
                        record['fullscreen_request']=on
                    elif action == 'finish':
                        frames = frame+1
                with canvas_probe.open('a') as stream:
                    stream.write(json.dumps(record)+'\n')
            clear(context, target, clear_color)
            for _ in range(gpu_draws):
                draw(context, 3, 0)
            if frame == frames - 1:
                # Read before Present: DISCARD swapchain content isn't defined
                # after presentation. Map intentionally waits for GPU results.
                method(context, 47, None, PTR, PTR)(context, staging, texture)
                mapped = Mapped()
                check(method(context, 14, HRESULT, PTR, UINT, UINT, UINT, c.POINTER(Mapped))(
                    context, staging, 0, 1, 0, c.byref(mapped)), "MapReadback")
                try:
                    if not mapped.data or mapped.row_pitch < width * 4:
                        raise RuntimeError("Invalid mapped texture layout")
                    for x, y in [(8, 8), (width // 2, height // 2), (width - 9, height - 9)]:
                        actual = list(c.string_at(mapped.data + y * mapped.row_pitch + x * 4, 4))
                        expected = [round((x + 0.5) / width * 255),
                                    round((y + 0.5) / height * 255), blue, 255]
                        if any(abs(a - e) > 2 for a, e in zip(actual, expected)):
                            raise RuntimeError(f"Readback mismatch at ({x},{y}): {actual}, expected {expected}")
                        pixel_results.append({"xy": [x, y], "rgba": actual})
                finally:
                    method(context, 15, None, PTR, UINT)(context, staging, 0)
            check(present(swapchain, 0, 0), "Present")
            if frame == frames-1:
                break

        check(method(device, 39, HRESULT)(device), "GetDeviceRemovedReason")
        print(json.dumps({"result": "PASS", "feature_level": f"0x{level.value:x}",
                          "backbuffer": [width, height], "blue": blue, "presents": frames,
                          "waitable_swapchain": waitable,
                          "baseline_presents": 1,
                          "verified_pixels": pixel_results,
                          "elapsed_seconds": round(time.perf_counter() - started, 3),
                          "note": "shader/draw/readback smoke test; not a game FPS benchmark"}), flush=True)
    finally:
        if context.value:
            method(context, 110, None)(context)  # ClearState releases bound objects.
            method(context, 111, None)(context)
        for pointer in reversed(owned):
            release(pointer)
        if window:
            user.DestroyWindow(window)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--frames", type=int, default=12)
    parser.add_argument("--width", type=int, default=320)
    parser.add_argument("--height", type=int, default=180)
    parser.add_argument("--blue", type=int, default=64,
                        help="Shader output byte; varying it creates a distinct pipeline for cold-cache checks.")
    parser.add_argument("--settle-ms", type=int, default=0,
                        help="Keep the diagnostic process alive after cleanup so asynchronous writers can drain.")
    parser.add_argument("--waitable", action="store_true", help="Exercise a flip-model frame-latency fence.")
    parser.add_argument("--gpu-draws", type=int, default=1,
                        help="Full-screen triangle draws per frame; hundreds make the diagnostic GPU-bound like the game.")
    parser.add_argument('--canvas-probe', type=Path, help='Geometry checkpoints and explicit cursor commands for the owned fixture.')
    parser.add_argument('--native-fixture', type=Path, help='Owned Winelib test helper; requires --canvas-probe.')
    args = parser.parse_args()
    if not 1 <= args.frames <= (36000 if args.canvas_probe else 600):
        parser.error("Frame count exceeds the bounded fixture duration")
    if not 32 <= args.width <= 3840 or not 32 <= args.height <= 2160:
        parser.error("Diagnostic dimensions must be 32–3840 by 32–2160")
    if not 0 <= args.blue <= 255:
        parser.error("--blue must be between 0 and 255")
    if not 0 <= args.settle_ms <= 5000:
        parser.error("--settle-ms must be between 0 and 5000")
    try:
        if args.native_fixture:
            if not args.canvas_probe:raise ValueError('Native fixture requires canvas diagnostics')
            native_fixture=c.WinDLL(str(args.native_fixture))
        run(args.frames, args.width, args.height, args.blue, args.waitable, args.canvas_probe, max(1, args.gpu_draws))
        time.sleep(args.settle_ms / 1000)
    except Exception as error:
        print(json.dumps({"result": "FAIL", "error": str(error)[:2400]}), flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
