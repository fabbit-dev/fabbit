#!/usr/bin/env python3
"""Упаковка битстрима профиля: .bit -> .fbp

.fbp = заголовок 64 байта + сырой поток конфигурации (как его читает ПЛИС из слота).
Заголовок (little-endian):
  0  'FBP1'          4  u16 id профиля   6  u8 флаги   7  u8 версия заголовка (1)
  8  u32 длина образа  12 u32 CRC32 образа (IEEE)   16 char[32] имя (UTF-8, нули в конце)
  48 u32 COR0 после правки   52..59 резерв   60 u32 CRC32 байтов 0..59
Правка: openXC7 пишет COR0 с OSCFSEL=0 (CCLK ~3 МГц, слот грузится ~7 с). Ставим поле частоты
как у Vivado с CONFIGRATE 33. CRC конфигурации в битстримах openXC7 нет, правка безопасна.

python3 fbp_pack.py <in.bit> <out.fbp> --id N --name ИМЯ [--rate-from 0x02423FE5]
"""
import argparse
import struct
import zlib

SYNC = b'\xaa\x99\x55\x66'
COR0_WRITE = 0x30012001  # type1 write COR0, 1 слово
OSCFSEL_MASK = 0x3F << 17


def bit_payload(data: bytes) -> bytes:
    """Сырой поток из .bit: поле 'e' заголовка Xilinx, иначе файл как есть (.bin)."""
    if data[:2] == b'\x00\x09':
        p = 2 + 9 + 2  # длина 9, 9 байт, 00 01
        while p < len(data):
            key = data[p]
            p += 1
            if key == ord('e'):
                n = struct.unpack('>I', data[p:p + 4])[0]
                return data[p + 4:p + 4 + n]
            n = struct.unpack('>H', data[p:p + 2])[0]
            p += 2 + n
        raise ValueError('нет поля e в .bit')
    return data


def patch_cor0(img: bytearray, rate_from: int) -> int:
    i = img.find(SYNC)
    if i < 0:
        raise ValueError('нет sync')
    w = struct.pack('>I', COR0_WRITE)
    j = img.find(w, i)
    if j < 0 or j - i > 256:
        raise ValueError('нет записи COR0 в заголовке потока')
    old = struct.unpack('>I', img[j + 4:j + 8])[0]
    new = (old & ~OSCFSEL_MASK) | (rate_from & OSCFSEL_MASK)
    img[j + 4:j + 8] = struct.pack('>I', new)
    return new


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('inp')
    ap.add_argument('out')
    ap.add_argument('--id', type=int, required=True)
    ap.add_argument('--name', required=True)
    ap.add_argument('--rate-from', type=lambda x: int(x, 0), default=0x02423FE5,
                    help='COR0 Vivado с нужным CONFIGRATE, берётся только поле OSCFSEL')
    a = ap.parse_args()
    img = bytearray(bit_payload(open(a.inp, 'rb').read()))
    cor0 = patch_cor0(img, a.rate_from)
    name = a.name.encode()[:31]
    hdr = struct.pack('<4sHBBII32sI8x', b'FBP1', a.id, 0, 1, len(img), zlib.crc32(img),
                      name.ljust(32, b'\0'), cor0)
    hdr += struct.pack('<I', zlib.crc32(hdr))
    assert len(hdr) == 64
    open(a.out, 'wb').write(hdr + img)
    print(f'{a.out}: id {a.id} "{a.name}" образ {len(img)} Б, CRC {zlib.crc32(img):08x}, COR0 {cor0:08x}')


if __name__ == '__main__':
    main()
