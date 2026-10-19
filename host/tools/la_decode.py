#!/usr/bin/env python3
"""Разбор дампа la_capture: строка 'L<hex>' из лога fpga_run. Биты: 0 SCK, 1 CS#, 2..5 IO0..3, 6 d_oe.
python3 la_decode.py <лог> : фронты SCK, нибл на каждом переднем фронте, d_oe."""
import re, sys
txt = open(sys.argv[1], errors='replace').read()
m = re.search(r'L([0-9A-F]{200,})', txt)
if not m:
    sys.exit('нет дампа')
h = m.group(1)
s = [int(h[i:i + 2], 16) for i in range(0, len(h) - 1, 2)]
print(f'выборок {len(s)} (10 нс)')
rises = [i for i in range(1, len(s)) if (s[i] & 1) and not (s[i - 1] & 1)]
falls = [i for i in range(1, len(s)) if not (s[i] & 1) and (s[i - 1] & 1)]
cs_up = next((i for i in range(len(s)) if s[i] & 2), None)
print(f'передних фронтов SCK {len(rises)}, задних {len(falls)}, CS# поднялся на {cs_up}')
if len(rises) > 1:
    per = [b - a for a, b in zip(rises, rises[1:])]
    print(f'период SCK: мин {min(per)}, макс {max(per)} выборок; паузы >2T: ' +
          str([(k + 1, p) for k, p in enumerate(per) if p > 2 * min(per)][:10]))
nib = [(s[i] >> 2) & 0xF for i in rises]
oe = [(s[i] >> 6) & 1 for i in rises]
print('ниблы (на переднем фронте):')
for k in range(0, len(nib), 32):
    print(f'{k:4d}: ' + ''.join('%X' % n for n in nib[k:k + 32]) + '  oe=' + ''.join(map(str, oe[k:k + 32])))
