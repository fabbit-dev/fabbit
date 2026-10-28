#!/usr/bin/env python3
"""Захват через консоль ESP: capture arm/status/read, RAW или PulseView .sr.

python la_capture.py cap.sr --port /dev/ttyACM1 --arm --samples 131072 --post 65536
python la_capture.py cap.bin --log console.log
Порт открывается только из main; нужен pyserial. --log обрабатывает готовую выгрузку без железа.
"""
import argparse
from contextlib import contextmanager
from dataclasses import asdict, dataclass
from fractions import Fraction
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import zlib


class CaptureError(ValueError):
    pass


ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
U32_MAX = (1 << 32) - 1
MAX_SAMPLES = 131072
BLOCK_BYTES = 1024


def integer(packet, key, maximum=U32_MAX):
    value = packet.get(key)
    if type(value) is not int or not 0 <= value <= maximum:
        raise CaptureError(f"Неверное поле {key}")
    return value


def packets(text):
    """Ignore console echo/logs, but reject damaged or duplicated protocol lines."""
    for line in ANSI.sub("", text).splitlines():
        at = line.find("@LA ")
        if at < 0:
            continue
        try:
            packet = json.loads(line[at + 4:])
        except (ValueError, TypeError) as error:
            raise CaptureError("Повреждённый ответ консоли") from error
        if not isinstance(packet, dict) or type(packet.get("ok")) is not bool:
            raise CaptureError("Повреждённый ответ консоли")
        yield packet


def checked(packet, operation):
    if packet.get("ok") is not True:
        raise CaptureError(str(packet.get("message", "Ошибка консоли")))
    if packet.get("op") != operation:
        raise CaptureError("Неверный тип ответа консоли")
    return packet


@dataclass(frozen=True)
class Descriptor:
    flags: int
    capacity: int
    base_hz: int
    count: int
    trigger_index: int
    epoch: int
    divider: int
    source: int

    @classmethod
    def parse(cls, packet):
        checked(packet, "status")
        result = cls(**{key: integer(packet, key) for key in cls.__dataclass_fields__})
        if (result.flags & ~15 or not 1 <= result.capacity <= MAX_SAMPLES or
                result.base_hz not in (100_000_000, 200_000_000, 400_000_000) or result.source > 1 or
                result.count > result.capacity):
            raise CaptureError("Повреждённый ответ ПЛИС")
        if result.flags & 4:
            if (result.flags != 6 or not result.count or result.trigger_index >= result.count):
                raise CaptureError("Повреждённый ответ ПЛИС")
        elif result.count or result.trigger_index:
            raise CaptureError("Повреждённый ответ ПЛИС")
        return result

    @property
    def rate(self):
        return Fraction(self.base_hz, self.divider + 1)


class LogConsole:
    """Offline replay of actual @LA output; same validation as serial downloads."""
    def __init__(self, text):
        self.responses = iter(packets(text))

    def exchange(self, command):
        try:
            return next(self.responses)
        except StopIteration as error:
            raise CaptureError("Обрезанный дамп консоли") from error


class SerialConsole:
    def __init__(self, port):
        self.port = port

    def response(self, timeout):
        deadline = time.monotonic() + timeout
        output = bytearray()
        while time.monotonic() < deadline:
            output.extend(self.port.read(4096))
            if len(output) > 65536:
                raise CaptureError("Ответ консоли превышает 64 КиБ")
            text = ANSI.sub("", output.decode("utf-8", errors="replace"))
            if text.rstrip().endswith("fabbit>"):
                return text
        raise CaptureError("Нет ответа консоли")

    def exchange(self, command):
        self.port.write((command + "\r\n").encode("ascii"))
        replies = list(packets(self.response(10)))
        if len(replies) != 1:
            raise CaptureError("Ожидался один ответ @LA")
        return replies[0]


@contextmanager
def open_console(name):
    import serial  # Optional dependency; importing/offline conversion never opens a port.
    port = serial.Serial()
    port.port = name
    port.baudrate = 115200
    port.timeout = 0.05
    port.write_timeout = 2
    port.dtr = False
    port.rts = False
    try:
        port.open()
        console = SerialConsole(port)
        # USB-Serial-JTAG can restart ESP on open. Wait for REPL without issuing capture commands.
        for attempt in range(20):
            port.write(b"\r\n")
            try:
                console.response(0.5)
                break
            except CaptureError:
                if attempt == 19:
                    raise
        yield console
    finally:
        port.close()


def block_data(packet, epoch, offset, size):
    checked(packet, "data")
    if integer(packet, "epoch") != epoch or integer(packet, "offset") != offset:
        raise CaptureError("Захват изменился во время чтения")
    encoded, crc = packet.get("hex"), packet.get("crc32")
    if (not isinstance(encoded, str) or len(encoded) != size * 2 or
            re.fullmatch(r"[0-9a-fA-F]+", encoded) is None or not isinstance(crc, str) or
            re.fullmatch(r"[0-9a-fA-F]{8}", crc) is None):
        raise CaptureError("Повреждённый блок захвата")
    data = bytes.fromhex(encoded)
    if zlib.crc32(data) != int(crc, 16):
        raise CaptureError("CRC32 блока не совпадает")
    return data


def validate_arm(arm):
    total, post, divider, mask, value, rise, fall, source = arm
    if (not 1 <= total <= MAX_SAMPLES or not 1 <= post <= total or
            not 0 <= divider <= U32_MAX or source not in (0, 1) or rise & fall or
            any(not 0 <= v <= 65535 for v in (mask, value, rise, fall))):
        raise CaptureError("Неверные параметры захвата")


def acquire(console, arm=None, timeout=10):
    if not math.isfinite(timeout) or timeout <= 0:
        raise CaptureError("Неверное время ожидания")
    command = "capture status"
    if arm is not None:
        validate_arm(arm)
        command = "capture arm " + " ".join(str(v) for v in arm)
    snapshot = Descriptor.parse(console.exchange(command))
    epoch = snapshot.epoch
    deadline = time.monotonic() + timeout
    while not snapshot.flags & 4:
        if snapshot.flags & 8 or not snapshot.flags & 1:
            raise CaptureError("Захват не запущен или параметры отвергнуты")
        if time.monotonic() >= deadline:
            raise CaptureError("Время ожидания триггера истекло")
        time.sleep(0.02)
        snapshot = Descriptor.parse(console.exchange("capture status"))
        if snapshot.epoch != epoch:
            raise CaptureError("Захват изменился во время чтения")
    data = bytearray()
    size = snapshot.count * 2
    while len(data) < size:
        offset = len(data)
        amount = min(BLOCK_BYTES, size - offset)
        packet = console.exchange(f"capture read {epoch} {offset} {amount}")
        data.extend(block_data(packet, epoch, offset, amount))
    final = Descriptor.parse(console.exchange("capture status"))
    if final != snapshot:
        raise CaptureError("Захват изменился во время чтения")
    return snapshot, bytes(data)


def save_capture(output, snapshot, data):
    """Publish only verified complete data; no overwrite, including the metadata sidecar."""
    output = Path(output)
    metadata_path = output.with_suffix(output.suffix + ".json")
    if output.suffix not in (".bin", ".sr"):
        raise CaptureError("Укажите файл .bin или .sr")
    if output.exists() or metadata_path.exists():
        raise CaptureError("Файл уже существует")
    if len(data) != snapshot.count * 2:
        raise CaptureError("Обрезанный захват")
    rate = snapshot.rate
    if output.suffix == ".sr" and rate.denominator != 1:
        raise CaptureError("Для .sr нужна целая частота в Гц; сохраните .bin с метаданными")
    metadata = {**asdict(snapshot), "channels": 16, "encoding": "LE16", "pinmap": "P2",
                "sample_rate_numerator": rate.numerator, "sample_rate_denominator": rate.denominator,
                "clock_calibrated": False, "crc32": f"{zlib.crc32(data):08x}"}
    with tempfile.TemporaryDirectory(prefix=".capture-", dir=output.parent) as directory:
        temporary = Path(directory)
        raw = temporary / "capture.bin"
        raw.write_bytes(data)
        result = raw
        if output.suffix == ".sr":
            result = temporary / "capture.sr"
            try:
                process = subprocess.run(
                    ["sigrok-cli", "-I", f"binary:numchannels=16:samplerate={rate.numerator}",
                     "-i", str(raw), "-o", str(result)], capture_output=True, timeout=30, check=False)
            except (OSError, subprocess.TimeoutExpired) as error:
                raise CaptureError("Не удалось запустить sigrok-cli") from error
            if process.returncode or not result.is_file():
                raise CaptureError("sigrok-cli не создал файл захвата")
        sidecar = temporary / "metadata.json"
        sidecar.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        os.link(result, output)  # Atomic no-clobber publication on the same filesystem.
        try:
            os.link(sidecar, metadata_path)
        except OSError:
            output.unlink()  # Only our newly-created output, never an existing user file.
            raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    transport = parser.add_mutually_exclusive_group(required=True)
    transport.add_argument("--port", help="Порт консоли ESP; открытие может перезапустить ESP")
    transport.add_argument("--log", type=Path, help="Готовая выгрузка @LA, без доступа к железу")
    parser.add_argument("--arm", action="store_true", help="Начать новый захват; иначе прочитать текущий")
    parser.add_argument("--samples", type=lambda v: int(v, 0),
                        help="Число отсчётов; по умолчанию ёмкость загруженного профиля")
    parser.add_argument("--post", type=lambda v: int(v, 0))
    parser.add_argument("--divider", type=lambda v: int(v, 0), default=0)
    for name in ("mask", "value", "rise", "fall", "source"):
        parser.add_argument("--" + name, type=lambda v: int(v, 0), default=0)
    parser.add_argument("--timeout", type=float, default=10)
    args = parser.parse_args(argv)
    if args.arm and args.log:
        parser.error("--arm нельзя сочетать с --log")
    capture_options = ("--samples", "--post", "--divider", "--mask", "--value", "--rise", "--fall", "--source")
    supplied = sys.argv[1:] if argv is None else argv
    if not args.arm and any(option.split("=", 1)[0] in capture_options for option in supplied):
        parser.error("Параметры захвата требуют --arm")
    try:
        if args.output.suffix not in (".bin", ".sr"):
            raise CaptureError("Укажите файл .bin или .sr")
        if args.output.exists() or args.output.with_suffix(args.output.suffix + ".json").exists():
            raise CaptureError("Файл уже существует")
        if not args.output.parent.is_dir():
            raise CaptureError("Каталог для захвата не существует")
        if not math.isfinite(args.timeout) or args.timeout <= 0:
            raise CaptureError("Неверное время ожидания")
        arm = None
        if args.arm:
            total = args.samples if args.samples is not None else MAX_SAMPLES
            post = args.post if args.post is not None else max(1, total // 2)
            arm = (total, post, args.divider, args.mask, args.value, args.rise, args.fall, args.source)
            validate_arm(arm)
        if args.log:
            snapshot, data = acquire(LogConsole(args.log.read_text(encoding="utf-8")), timeout=args.timeout)
        else:
            with open_console(args.port) as console:
                if args.arm and args.samples is None:
                    capability = Descriptor.parse(console.exchange("capture status"))
                    post = args.post if args.post is not None else max(1, capability.capacity // 2)
                    arm = (capability.capacity, post, *arm[2:])
                snapshot, data = acquire(console, arm, args.timeout)
        save_capture(args.output, snapshot, data)
        print(f"{args.output}: {snapshot.count} отсчётов, {snapshot.rate} Гц, "
              f"триггер {snapshot.trigger_index}, CRC32 {zlib.crc32(data):08x}")
        return 0
    except (CaptureError, OSError, ImportError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    raise SystemExit(main())
