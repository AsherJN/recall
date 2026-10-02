"""Control only a selected Battle.net/Overwatch window inside the experiment Wine prefix.

Used for menu verification where macOS app automation cannot attach to Wine.
No process command lines, environment or account configuration are inspected.
"""
import argparse
import ctypes as c
import json
import sys
import time

if sys.platform != 'win32':raise SystemExit('Run with the experiment Windows Python')
P=c.c_void_p;I=c.c_int32;U=c.c_uint32
class Rect(c.Structure):_fields_=[('left',I),('top',I),('right',I),('bottom',I)]
class Point(c.Structure):_fields_=[('x',I),('y',I)]
class Mouse(c.Structure):_fields_=[('dx',I),('dy',I),('data',U),('flags',U),('time',U),('extra',c.c_uint64)]
class Key(c.Structure):_fields_=[('vk',c.c_uint16),('scan',c.c_uint16),('flags',U),('time',U),('extra',c.c_uint64)]
class Payload(c.Union):_fields_=[('mouse',Mouse),('key',Key)]
class Input(c.Structure):_fields_=[('type',U),('payload',Payload)]
assert c.sizeof(Input)==40
user=c.WinDLL('user32');kernel=c.WinDLL('kernel32')
user.GetWindowThreadProcessId.argtypes=[P,c.POINTER(U)]
kernel.OpenProcess.argtypes=[U,I,U];kernel.OpenProcess.restype=P
kernel.CloseHandle.argtypes=[P]
kernel.QueryFullProcessImageNameW.argtypes=[P,U,c.c_wchar_p,c.POINTER(U)]
user.IsWindowVisible.argtypes=[P]
user.GetClientRect.argtypes=[P,c.POINTER(Rect)]
user.ClientToScreen.argtypes=[P,c.POINTER(Point)]
user.SetForegroundWindow.argtypes=[P]
user.GetForegroundWindow.restype=P
user.SetCursorPos.argtypes=[I,I]
user.SendInput.argtypes=[U,c.POINTER(Input),I];user.SendInput.restype=U
callback=c.WINFUNCTYPE(I,P,c.c_ssize_t)
user.EnumWindows.argtypes=[callback,c.c_ssize_t]

def windows(exe):
    result=[]
    @callback
    def visit(hwnd,unused):
        pid=U();user.GetWindowThreadProcessId(hwnd,c.byref(pid))
        proc=kernel.OpenProcess(0x1000,0,pid.value)
        if not proc:return 1
        try:
            text=c.create_unicode_buffer(4096);size=U(len(text))
            if not kernel.QueryFullProcessImageNameW(proc,0,text,c.byref(size)):return 1
            if text.value.rsplit('\\',1)[-1].lower()!=exe.lower():return 1
            rect=Rect()
            if user.IsWindowVisible(hwnd) and user.GetClientRect(hwnd,c.byref(rect)) and rect.right>=500 and rect.bottom>=300:
                result.append(dict(hwnd=int(hwnd),windows_pid=pid.value,client=[rect.right,rect.bottom]))
        finally:kernel.CloseHandle(proc)
        return 1
    user.EnumWindows(visit,0)
    return result

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app',choices=['Overwatch.exe','Battle.net.exe'],required=True)
parser.add_argument('--hwnd',type=int)
actions=parser.add_mutually_exclusive_group()
actions.add_argument('--key',choices=['escape','enter','printscreen','tab'])
actions.add_argument('--click',nargs=2,type=int,metavar=('X','Y'))
actions.add_argument('--capture',help='Print only the verified application window into a local BMP')
args=parser.parse_args();found=windows(args.app)
print(json.dumps(dict(app=args.app,windows=found)),flush=True)
if not (args.key or args.click or args.capture):raise SystemExit(0)
selected=[w for w in found if w['hwnd']==args.hwnd] if args.hwnd else found
if len(selected)!=1:raise SystemExit('Select exactly one verified visible game/launcher window')
w=selected[0];hwnd=w['hwnd']
if args.capture:
    import struct
    from pathlib import Path
    gdi=c.WinDLL('gdi32')
    user.GetDC.argtypes=[P];user.GetDC.restype=P
    user.ReleaseDC.argtypes=[P,P]
    gdi.CreateCompatibleDC.argtypes=[P];gdi.CreateCompatibleDC.restype=P
    gdi.CreateCompatibleBitmap.argtypes=[P,I,I];gdi.CreateCompatibleBitmap.restype=P
    gdi.SelectObject.argtypes=[P,P];gdi.SelectObject.restype=P
    gdi.GetDIBits.argtypes=[P,P,U,U,P,P,U]
    gdi.DeleteObject.argtypes=[P];gdi.DeleteDC.argtypes=[P]
    user.PrintWindow.argtypes=[P,P,U]
    width,height=w['client'];dc=user.GetDC(hwnd);mem=gdi.CreateCompatibleDC(dc);bitmap=gdi.CreateCompatibleBitmap(dc,width,height)
    old=gdi.SelectObject(mem,bitmap)
    try:
        if not user.PrintWindow(hwnd,mem,3):raise RuntimeError('Application PrintWindow unavailable')
        header=struct.pack('<IiiHHIIiiII',40,width,-height,1,32,0,width*height*4,0,0,0,0)
        info=c.create_string_buffer(header,40);pixels=c.create_string_buffer(width*height*4)
        if gdi.GetDIBits(mem,bitmap,0,height,pixels,info,0)!=height:raise RuntimeError('Window pixels unavailable')
        Path(args.capture).write_bytes(struct.pack('<2sIHHI',b'BM',54+len(pixels.raw),0,0,54)+header+pixels.raw)
        print(json.dumps({'capture':args.capture,'size':[width,height]}))
    finally:
        gdi.SelectObject(mem,old);gdi.DeleteObject(bitmap);gdi.DeleteDC(mem);user.ReleaseDC(hwnd,dc)
    raise SystemExit(0)
user.SetForegroundWindow(hwnd)
for _ in range(30):
    if user.GetForegroundWindow()==hwnd:break
    time.sleep(.05)
if user.GetForegroundWindow()!=hwnd:raise SystemExit('Selected window did not become foreground; no input sent')
events=(Input*2)()
if args.key:
    vk={'escape':0x1b,'enter':0x0d,'printscreen':0x2c,'tab':9}[args.key]
    events[0].type=events[1].type=1
    events[0].payload.key=Key(vk,0,0,0,0);events[1].payload.key=Key(vk,0,2,0,0)
else:
    x,y=args.click
    if not (0<=x<w['client'][0] and 0<=y<w['client'][1]):raise SystemExit('Click is outside the verified client')
    point=Point(x,y)
    if not user.ClientToScreen(hwnd,c.byref(point)):raise SystemExit('Client coordinate conversion failed')
    if not user.SetCursorPos(point.x,point.y):raise SystemExit('Cursor positioning failed')
    time.sleep(.1)
    events[0].payload.mouse=Mouse(0,0,0,2,0,0);events[1].payload.mouse=Mouse(0,0,0,4,0,0)
if user.GetForegroundWindow()!=hwnd:raise SystemExit('Focus changed; no input sent')
if user.SendInput(2,events,c.sizeof(Input))!=2:raise SystemExit('Input delivery failed')
print(json.dumps(dict(sent=args.key or 'click',target_hwnd=hwnd)),flush=True)
