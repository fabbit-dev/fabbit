#!/usr/bin/env python3
"""Загрузить битстрим в SRAM ПЛИС (DAPLink) и читать UART ПЛИС N секунд.
uv run --with pyserial python fpga_run.py <bit|-> [секунд]   ('-' без загрузки)
DAPLink буферизует UART: старое сливаем до загрузки. Нужен DTR."""
import glob, os, shutil, subprocess, sys, time
import serial

bit = sys.argv[1]
T = float(sys.argv[2]) if len(sys.argv) > 2 else 10
s = serial.Serial(glob.glob('/dev/serial/by-id/*DAPLink*')[0], 115200, timeout=0.2)
s.dtr = True
s.rts = True
t = time.time()
while time.time() - t < 1.5:
    s.read(4096)
if bit != '-':
    # не прерывать: убитый посреди загрузки openFPGALoader вешает DAPLink до переподключения USB
    r = subprocess.run([os.environ.get('OPENFPGALOADER') or shutil.which('openFPGALoader') or 'openFPGALoader', '-c', 'cmsisdap',
                        '-b', 'colorlight-i9+', bit], capture_output=True, text=True)
    print('[load]', (r.stdout + r.stderr).strip().splitlines()[-1], flush=True)
t0 = time.time()
line = b''
while time.time() - t0 < T:
    c = s.read(256)
    for ch in c:
        if ch == 10:
            print(f'[{time.time() - t0:6.2f}] {line.decode(errors="replace").strip()}', flush=True)
            line = b''
        else:
            line += bytes([ch])
if line:
    print(f'[хвост] {line.decode(errors="replace").strip()}', flush=True)
