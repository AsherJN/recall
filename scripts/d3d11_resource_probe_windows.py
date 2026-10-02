"""Isolated real D3D11 resource/copy/map/readback checks; never opens Overwatch."""
import ctypes as c
import json
from pathlib import Path
import sys
import time
sys.path.insert(0, str(Path(__file__).resolve().parent))
from d3d11_render_probe_windows import PTR, UINT, HRESULT, Mapped, TextureDesc, Samples, method, check, release


class BufferDesc(c.Structure):
    _fields_ = [(name, UINT) for name in ['bytes', 'usage', 'bind', 'cpu', 'misc', 'stride']]


class Initial(c.Structure):
    _fields_ = [('data', PTR), ('row', UINT), ('depth', UINT)]


def run():
    assert c.sizeof(BufferDesc) == 24 and c.sizeof(Initial) == 16
    d3d = c.WinDLL('d3d11.dll')
    create = d3d.D3D11CreateDevice
    create.argtypes = [PTR, UINT, PTR, UINT, PTR, UINT, UINT, c.POINTER(PTR), c.POINTER(UINT), c.POINTER(PTR)]
    create.restype = HRESULT
    device, context, deferred, level = PTR(), PTR(), PTR(), UINT()
    owned = [device, context, deferred]
    passed = []
    try:
        check(create(None, 1, None, 0, None, 0, 7, c.byref(device), c.byref(level), c.byref(context)), 'CreateDevice')
        def buffer(size, usage, bind, cpu):
            pointer = PTR(); owned.append(pointer)
            desc = BufferDesc(size, usage, bind, cpu, 0, 0)
            check(method(device, 3, HRESULT, c.POINTER(BufferDesc), PTR, c.POINTER(PTR))(
                device, c.byref(desc), None, c.byref(pointer)), 'CreateBuffer')
            return pointer
        def texture(usage, bind, cpu, initial=None):
            pointer = PTR(); owned.append(pointer)
            desc = TextureDesc(64, 64, 1, 1, 28, Samples(1, 0), usage, bind, cpu, 0)
            check(method(device, 5, HRESULT, c.POINTER(TextureDesc), PTR, c.POINTER(PTR))(
                device, c.byref(desc), c.byref(initial) if initial else None, c.byref(pointer)), 'CreateTexture2D')
            return pointer
        def mapping(ctx, resource, kind):
            mapped = Mapped()
            check(method(ctx, 14, HRESULT, PTR, UINT, UINT, UINT, c.POINTER(Mapped))(
                ctx, resource, 0, kind, 0, c.byref(mapped)), 'Map')
            assert mapped.data
            return mapped
        def unmap(ctx, resource):
            method(ctx, 15, None, PTR, UINT)(ctx, resource, 0)
        def copy(dst, src):
            method(context, 47, None, PTR, PTR)(context, dst, src)
        def update(dst, data, row=0, depth=0):
            method(context, 48, None, PTR, UINT, PTR, PTR, UINT, UINT)(context, dst, 0, None, data, row, depth)
        def verify_buffer(resource, expected):
            mapped = mapping(context, resource, 1)
            try: assert c.string_at(mapped.data, len(expected)) == expected
            finally: unmap(context, resource)
        size = 1024 * 1024
        expected = bytes(range(256)) * (size // 256)
        payload = c.create_string_buffer(expected)
        dynamic = buffer(size, 2, 1, 0x10000)
        default = buffer(size, 0, 1, 0)
        staging = buffer(size, 3, 0, 0x30000)
        mapped = mapping(context, dynamic, 4)
        time.sleep(.006)  # Known application-held mapping interval, outside Map/Unmap APIs.
        c.memmove(mapped.data, payload, size); unmap(context, dynamic)
        copy(staging, dynamic); verify_buffer(staging, expected)
        passed.append('immediate dynamic discard, copy, staging readback')
        update(default, payload)
        copy(staging, default); verify_buffer(staging, expected)
        passed.append('default buffer upload and exact 1 MiB readback')
        # A GPU reader followed by CPU write exercises preservation when renamed.
        copy(default, staging)
        mapped = mapping(context, staging, 2)
        c.memset(mapped.data, 173, 1); unmap(context, staging)
        verify_buffer(staging, bytes([173])+expected[1:])
        passed.append('staging write preserves remaining bytes')
        check(method(device, 27, HRESULT, UINT, c.POINTER(PTR))(device, 0, c.byref(deferred)), 'CreateDeferredContext')
        mapped = mapping(deferred, dynamic, 4)
        time.sleep(.006)
        c.memmove(mapped.data, payload, size); unmap(deferred, dynamic)
        commands = PTR(); owned.append(commands)
        check(method(deferred, 114, HRESULT, UINT, c.POINTER(PTR))(deferred, 0, c.byref(commands)), 'FinishCommandList')
        method(context, 58, None, PTR, UINT)(context, commands, 0)
        copy(staging, dynamic); verify_buffer(staging, expected)
        passed.append('deferred map/upload, command execution, exact readback')
        pitch = 320
        row = bytes(range(256))
        padded = c.create_string_buffer((row+bytes([91])*64)*64)
        initial = Initial(c.cast(padded, PTR), pitch, pitch*64)
        tex = texture(0, 8, 0, initial)
        tex_read = texture(3, 0, 0x20000)
        for label in ['initial texture upload with padded rows', 'UpdateSubresource texture with padded rows']:
            if label.startswith('Update'): update(tex, padded, pitch, pitch*64)
            copy(tex_read, tex)
            mapped = mapping(context, tex_read, 1)
            try:
                assert all(c.string_at(mapped.data+y*mapped.row_pitch, 256) == row for y in range(64))
            finally: unmap(context, tex_read)
            passed.append(label)
        # Repeated independent allocations and final releases, bounded to 8 MiB.
        for cycle in range(8):
            batch = [buffer(size, 0, 1, 0) for _ in range(8)]
            for pointer in batch: release(pointer)
        method(context, 110, None)(context)
        method(context, 111, None)(context)
        check(method(device, 39, HRESULT)(device), 'GetDeviceRemovedReason')
        passed.append('64 buffer allocations/releases; device healthy')
    finally:
        for pointer in reversed(owned): release(pointer)
    # Allow the utility writers to snapshot completed work before process detach.
    time.sleep(3.0)
    print(json.dumps({'result': 'PASS', 'checks': passed}), flush=True)


if __name__ == '__main__':
    try: run()
    except Exception as error:
        print(json.dumps({'result': 'FAIL', 'error': str(error)}), flush=True)
        raise
