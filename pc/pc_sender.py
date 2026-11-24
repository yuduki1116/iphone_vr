"""PC画面をiPhone(VR OS)へ送る。USB(usbmuxd)がデフォルト、--host IP でWi-Fiも可。
Windowsは iTunes か Apple Devices アプリを入れておくこと(usbmuxdが必要)。"""
import argparse, io, json, os, plistlib, socket, struct, threading, time
import mss
import pyautogui
from PIL import Image

pyautogui.PAUSE = 0
pyautogui.FAILSAFE = False
if os.name == "nt":
    import ctypes
    ctypes.windll.shcore.SetProcessDpiAwareness(2)   # 画面座標を物理ピクセルに揃える

def recvn(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c: raise ConnectionError("closed")
        b += c
    return b

def mux_connect(port):
    if os.name == "nt":
        s = socket.create_connection(("127.0.0.1", 27015))
    else:
        s = socket.socket(socket.AF_UNIX); s.connect("/var/run/usbmuxd")
    tag = [0]
    def send(d):
        tag[0] += 1
        p = plistlib.dumps(d)
        s.sendall(struct.pack("<IIII", 16 + len(p), 1, 8, tag[0]) + p)
    def recv():
        n = struct.unpack("<I", recvn(s, 16)[:4])[0]
        return plistlib.loads(recvn(s, n - 16))
    base = {"ClientVersionString": "pc_sender", "ProgName": "pc_sender"}
    send({**base, "MessageType": "ListDevices"})
    usb = [d for d in recv().get("DeviceList", []) if d["Properties"].get("ConnectionType") == "USB"]
    if not usb: raise RuntimeError("iPhoneがUSBで見つからない")
    send({**base, "MessageType": "Connect", "DeviceID": usb[0]["DeviceID"], "PortNumber": socket.htons(port)})
    r = recv()
    if r.get("Number") != 0: raise RuntimeError(f"接続失敗 {r} (VR OSを起動してる?)")
    return s

def type_text(s):
    """日本語を含む文字列をそのままタイプする(WindowsはSendInputのUnicode入力)"""
    if os.name != "nt":
        pyautogui.write(s); return
    import ctypes
    from ctypes import wintypes
    ULP = ctypes.POINTER(ctypes.c_ulong)
    class MOUSEINPUT(ctypes.Structure):
        _fields_ = [("dx", wintypes.LONG), ("dy", wintypes.LONG), ("mouseData", wintypes.DWORD),
                    ("dwFlags", wintypes.DWORD), ("time", wintypes.DWORD), ("dwExtraInfo", ULP)]
    class KEYBDINPUT(ctypes.Structure):
        _fields_ = [("wVk", wintypes.WORD), ("wScan", wintypes.WORD), ("dwFlags", wintypes.DWORD),
                    ("time", wintypes.DWORD), ("dwExtraInfo", ULP)]
    class _U(ctypes.Union):
        _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT)]
    class INPUT(ctypes.Structure):
        _fields_ = [("type", wintypes.DWORD), ("u", _U)]
    for n, part in enumerate(s.split("\n")):
        if n: pyautogui.press("enter")
        b = part.encode("utf-16-le")
        units = [int.from_bytes(b[i:i + 2], "little") for i in range(0, len(b), 2)]
        if not units: continue
        arr = (INPUT * (len(units) * 2))()
        for i, u in enumerate(units):
            for j, fl in enumerate((0x0004, 0x0004 | 0x0002)):
                x = arr[i * 2 + j]; x.type = 1; x.u.ki = KEYBDINPUT(0, u, fl, 0, None)
        ctypes.windll.user32.SendInput(len(arr), arr, ctypes.sizeof(INPUT))

def handle(e, mon):
    t = e["t"]
    if t == "m":
        pyautogui.moveTo(mon["left"] + int(e["x"] * mon["width"]), mon["top"] + int(e["y"] * mon["height"]))
    elif t == "d": pyautogui.mouseDown(button=e.get("b", "left"))
    elif t == "u": pyautogui.mouseUp(button=e.get("b", "left"))
    elif t == "c": pyautogui.click(button=e.get("b", "left"), clicks=e.get("n", 1))
    elif t == "s": pyautogui.scroll(int(e["d"]))
    elif t == "text": type_text(e["s"])
    elif t == "k":
        mods = e.get("m", [])
        for k in mods: pyautogui.keyDown(k)
        pyautogui.press(e["k"])
        for k in reversed(mods): pyautogui.keyUp(k)

def listen(sock, mon):
    """iPhoneからの操作(1行1JSON)を受けてPCを操作する"""
    buf = b""
    try:
        while True:
            d = sock.recv(4096)
            if not d: return
            buf += d
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                try: handle(json.loads(line), mon)
                except Exception as ex: print("操作エラー:", ex)
    except OSError:
        return

def stream(sock, fps, quality, mon_idx):
    with mss.mss() as m:
        mon = m.monitors[mon_idx]
        threading.Thread(target=listen, args=(sock, mon), daemon=True).start()
        while True:
            t = time.time()
            shot = m.grab(mon)
            img = Image.frombytes("RGB", shot.size, shot.bgra, "raw", "BGRX")
            if img.width > 1920: img = img.resize((1920, img.height * 1920 // img.width))
            b = io.BytesIO(); img.save(b, "JPEG", quality=quality)
            d = b.getvalue()
            sock.sendall(struct.pack(">I", len(d)) + d)
            time.sleep(max(0, 1 / fps - (time.time() - t)))

if __name__ == "__main__":
    a = argparse.ArgumentParser()
    a.add_argument("--host"); a.add_argument("--port", type=int, default=5555)
    a.add_argument("--fps", type=int, default=30); a.add_argument("--quality", type=int, default=70)
    a.add_argument("--monitor", type=int, default=1)
    o = a.parse_args()
    while True:
        try:
            sock = socket.create_connection((o.host, o.port)) if o.host else mux_connect(o.port)
            print("接続した。送信中...")
            stream(sock, o.fps, o.quality, o.monitor)
        except Exception as e:
            print("待機中:", e); time.sleep(2)
