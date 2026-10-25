#!/usr/bin/env python3
"""Превью игр для лаунчера: <rom>.fbi рядом с каждым .nes.

Порядок поиска картинки для ROM:
  1. CRC-32 файла (с заголовком iNES и без него) в базе No-Intro libretro-database → титульный
     экран из libretro-thumbnails (Named_Titles), имя игры из базы;
  2. --map файл=«имя в No-Intro» (хаки, переводы, сокращённые имена файлов) → то же;
  3. имя файла почти совпадает с именем в базе (римские цифры = арабские, номера частей должны
     совпасть, порог --fuzzy) → то же;
  4. кадр из прогона ядра NES в Verilator (gateware: make sim_nes собирает build/tb_nes),
     +frames=--frames, Start не нажимается. Медленно: ~2,5 с на кадр;
  5. ничего: .fbi не пишется, лаунчер покажет «нет превью».
База и картинки кэшируются в ~/.cache/fabbit/libretro.

.fbi: "FBTH", u16 ширина 240, u16 высота 224 (LE), название UTF-8 64 байта (нули в конце),
затем пиксели 4 бита построчно, старший нибл левее; 16 серых, индекс i = 17·i (палитра golden).
Кадр NES 256×240 обрезается на 8 пикселей с каждого края, как у телевизора.

--rename: файл ROM (и его .fbi) получает имя игры из базы: «Super Mario Bros. 3.nes». Файлы не
из базы остаются как есть. Занятое имя получает номер: «Tetris (2).nes».

uv run --with pillow python rom_thumbs.py profiles/roms [--force] [--frames 60] [--no-sim]
    [--rename] [--map "smb3.nes=Super Mario Bros. 3 (USA)"]
"""
import argparse
import difflib
import os
import re
import struct
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
import zlib

from PIL import Image, ImageOps

DAT_URL = ('https://raw.githubusercontent.com/libretro/libretro-database/master/metadat/no-intro/'
           'Nintendo%20-%20Nintendo%20Entertainment%20System.dat')
THUMB_URL = ('https://raw.githubusercontent.com/libretro-thumbnails/'
             'Nintendo_-_Nintendo_Entertainment_System/master/Named_Titles/{}.png')
CACHE = os.path.expanduser('~/.cache/fabbit/libretro')
GATEWARE = os.path.normpath(os.path.join(os.path.dirname(__file__), '../../gateware'))
TW, TH = 240, 224


def fetch(url, path):
    if not os.path.exists(path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        try:
            with urllib.request.urlopen(url, timeout=30) as r:
                data = r.read()
        except Exception:
            return None
        with open(path, 'wb') as f:
            f.write(data)
    return path


def load_dat():
    path = fetch(DAT_URL, f'{CACHE}/nes.dat')
    if not path:
        sys.exit('нет базы No-Intro: проверь сеть')
    by_crc, names = {}, set()
    game = None
    for line in open(path, encoding='utf-8', errors='replace'):
        m = re.match(r'\s*name "(.*)"$', line)
        if m:
            game = m.group(1)
            names.add(game)
            continue
        m = re.search(r'\brom \( name ".*" size \d+ crc ([0-9A-Fa-f]{8})', line)
        if m and game:
            by_crc[m.group(1).lower()] = game
    return by_crc, sorted(names)


def title_of(game):
    """«Super Mario Bros. 3 (USA) (Rev 1)» → «Super Mario Bros. 3»."""
    t = re.sub(r'\s*\([^)]*\)', '', game).strip()
    m = re.match(r'(.*), (The|A|An)$', t)  # «Legend of Zelda, The» → «The Legend of Zelda»
    return f'{m.group(2)} {m.group(1)}' if m else t


ROMAN = {'ii': '2', 'iii': '3', 'iv': '4', 'v': '5', 'vi': '6', 'vii': '7', 'viii': '8'}


def norm(s):
    """Ключ для сравнения имён: «Final Fantasy III (Japan)» и «finalfantasy3» → «finalfantasy3»."""
    words = re.sub(r'[^a-z0-9]+', ' ', title_of(s).lower()).split()
    return ''.join(ROMAN.get(w, w) for w in words)


def fuzzy(key, by_norm, cutoff):
    if key in by_norm:
        return by_norm[key]
    digits = re.findall(r'\d+', key)
    for m in difflib.get_close_matches(key, by_norm, n=5, cutoff=cutoff):
        if re.findall(r'\d+', m) == digits:  # «Final Fantasy» не подходит к «finalfantasy3»
            return by_norm[m]
    return None


def thumb_from_db(game, by_norm_all):
    """Титульный экран игры; нет у этой версии — у другой версии той же игры (USA, Europe…)."""
    for g in [game] + [x for x in by_norm_all.get(norm(game), []) if x != game]:
        safe = re.sub(r'[&*/:`<>?\\|"]', '_', g)  # правило имён libretro-thumbnails
        path = fetch(THUMB_URL.format(urllib.parse.quote(safe)), f'{CACHE}/titles/{safe}.png')
        if path:
            return Image.open(path).convert('RGB')
    return None


def thumb_from_sim(rom, frames):
    sim = f'{GATEWARE}/build/tb_nes/Vtb_nes'
    if not os.path.exists(sim):
        print('  нет build/tb_nes: собери `make -C gateware sim_nes`')
        return None
    with tempfile.TemporaryDirectory() as d:
        hexf, ppm = f'{d}/rom.hex', f'{d}/frame.ppm'
        with open(hexf, 'w') as f:
            f.write('\n'.join(f'{b:02x}' for b in open(rom, 'rb').read()))
        print(f'  Verilator: {frames} кадров (~{frames * 2.7:.0f} с)')
        r = subprocess.run([sim, f'+rom={hexf}', f'+frames={frames}', f'+ppm={ppm}'], cwd=GATEWARE,
                           capture_output=True, text=True)
        if r.returncode or not os.path.exists(ppm):
            print('  прогон не удался')
            return None
        return Image.open(ppm).convert('RGB')


def to_fbi(img, title):
    if img.size != (256, 240):
        img = img.resize((256, 240), Image.NEAREST)
    g = img.crop((8, 8, 8 + TW, 8 + TH)).convert('L')
    g = ImageOps.autocontrast(g, cutoff=1)
    px = [round(v * 15 / 255) for v in g.tobytes()]
    body = bytes(px[i] << 4 | px[i + 1] for i in range(0, len(px), 2))
    name = title.encode('utf-8')[:63]
    while True:  # не резать UTF-8 посреди символа
        try:
            name.decode('utf-8')
            break
        except UnicodeDecodeError:
            name = name[:-1]
    return b'FBTH' + struct.pack('<HH', TW, TH) + name.ljust(64, b'\0') + body


def rename(rom, title):
    d = os.path.dirname(rom)
    base = re.sub(r'[\\/:*?"<>|]', '', title).strip()
    new, k = os.path.join(d, base + '.nes'), 2
    while os.path.exists(new) and not os.path.samefile(new, rom):
        new, k = os.path.join(d, f'{base} ({k}).nes'), k + 1
    if new != rom:
        os.rename(rom, new)
        if os.path.exists(rom[:-4] + '.fbi'):
            os.rename(rom[:-4] + '.fbi', new[:-4] + '.fbi')
        print(f'  переименован: {os.path.basename(new)}')
    return new


def main():
    ap = argparse.ArgumentParser(description='превью игр NES для лаунчера (.fbi)')
    ap.add_argument('dir')
    ap.add_argument('--force', action='store_true', help='переписать готовые .fbi')
    ap.add_argument('--frames', type=int, default=60, help='кадр Verilator для ROM не из базы')
    ap.add_argument('--map', action='append', default=[], metavar='ФАЙЛ=ИГРА',
                    help='игра из No-Intro для файла, которого нет в базе по CRC')
    ap.add_argument('--no-sim', action='store_true', help='без Verilator')
    ap.add_argument('--rename', action='store_true', help='переименовать ROM по имени игры из базы')
    ap.add_argument('--fuzzy', type=float, default=0.86, help='порог похожести имени файла')
    a = ap.parse_args()
    by_crc, names = load_dat()
    by_norm, by_norm_all = {}, {}
    for n in names:  # первой по алфавиту идёт версия без пометок или (USA), (Europe) и (Japan) позже
        by_norm.setdefault(norm(n), n)
        by_norm_all.setdefault(norm(n), []).append(n)
    maps = dict(m.split('=', 1) for m in a.map)
    for fn in sorted(os.listdir(a.dir)):
        if not fn.lower().endswith('.nes'):
            continue
        rom = os.path.join(a.dir, fn)
        out = rom[:-4] + '.fbi'
        if os.path.exists(out) and not a.force and not a.rename:
            print(f'{fn}: есть')
            continue
        data = open(rom, 'rb').read()
        crcs = [f'{zlib.crc32(data):08x}', f'{zlib.crc32(data[16:]):08x}']
        game = next((by_crc[c] for c in crcs if c in by_crc), None)
        how = 'CRC'
        if not game and fn in maps:
            game, how = maps[fn], '--map'
        if not game:
            game, how = fuzzy(norm(fn[:-4]), by_norm, a.fuzzy), 'имя'
        img, title = None, fn[:-4]
        if game:
            title = title_of(game)
            print(f'{fn}: {how} → {game}')
            if a.rename:
                rom = rename(rom, title)
                out = rom[:-4] + '.fbi'
            if os.path.exists(out) and not a.force:
                continue
            img = thumb_from_db(game, by_norm_all)
            if not img:
                print('  картинки в базе нет')
        else:
            print(f'{fn}: нет в No-Intro (CRC {crcs[0]})')
        if not img and not a.no_sim:
            img = thumb_from_sim(rom, a.frames)
        if not img:
            print('  превью нет')
            continue
        open(out, 'wb').write(to_fbi(img, title))
        print(f'  → {os.path.basename(out)} «{title}»')


if __name__ == '__main__':
    main()
