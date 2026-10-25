#!/usr/bin/env python3
"""Команды в консоль ESP (USB-Serial-JTAG). uv run --with pyserial python esp_cmd.py "id" "bench 20" ...
Открытие порта может перезагрузить ESP: сначала ждём приглашение, потом шлём команды."""
import glob, sys, time
import serial

PROMPT = b'fabbit>'
s = serial.Serial()
s.port = glob.glob('/dev/serial/by-id/*Espressif*')[0]
s.baudrate = 115200
s.timeout = 0.1
s.dtr = False
s.rts = False
s.open()


def wait_prompt(limit):
    buf = b''
    t = time.time()
    while time.time() - t < limit:
        buf += s.read(4096)
        if buf.rstrip().endswith(PROMPT):
            return buf, True
    return buf, False


ok = False
for _ in range(20):  # до ~10 с на загрузку
    s.write(b'\r\n')
    _, ok = wait_prompt(0.5)
    if ok:
        break
if not ok:
    sys.exit('ESP не отвечает')
for c in sys.argv[1:]:
    s.write((c + '\r\n').encode())
    buf, ok = wait_prompt(120)
    out = buf.decode(errors='replace').replace('\r', '').replace('fabbit>', '').strip()
    print(out if ok else out + '\n[нет приглашения]', flush=True)
