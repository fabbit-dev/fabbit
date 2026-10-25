import copy
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile
import zlib

TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))
import la_capture as la


def status(**updates):
    result = dict(ok=True, op="status", flags=6, capacity=131072, base_hz=100_000_000,
                  count=2048, trigger_index=1024, epoch=7, divider=0, source=1)
    return {**result, **updates}


def transcript(data, descriptor=None):
    descriptor = descriptor or status(count=len(data)//2, trigger_index=0)
    responses = [descriptor]
    for offset in range(0, len(data), la.BLOCK_BYTES):
        block = data[offset:offset+la.BLOCK_BYTES]
        responses.append(dict(ok=True, op="data", epoch=descriptor["epoch"], offset=offset,
                              crc32=f"{zlib.crc32(block):08x}", hex=block.hex()))
    responses.append(descriptor.copy())
    return responses


def as_log(responses):
    return "boot log\n" + "\n".join("\x1b[32m@LA " + json.dumps(p) + "\x1b[0m" for p in responses)


class CaptureTests(unittest.TestCase):
    def setUp(self):
        self.raw = b"".join(struct.pack("<H", i) for i in range(2048))
        self.replies = transcript(self.raw, status())

    def test_roundtrip(self):
        descriptor, data = la.acquire(la.LogConsole(as_log(self.replies)))
        self.assertEqual(data, self.raw)
        self.assertEqual(descriptor.rate, 100_000_000)
        self.assertEqual(descriptor.trigger_index, 1024)

    def test_full_depth_and_short_tail(self):
        raw = bytes(range(256)) * 1024  # all 256 KiB of the hardware snapshot
        descriptor, data = la.acquire(la.LogConsole(as_log(transcript(
            raw, status(count=131072, trigger_index=65536)))))
        self.assertEqual(data, raw)
        self.assertEqual(descriptor.count, 131072)
        short = self.raw[:2050]
        _, data = la.acquire(la.LogConsole(as_log(transcript(short))))
        self.assertEqual(data, short)  # final block contains only two bytes

    def test_bad_blocks(self):
        alterations = [dict(epoch=8), dict(offset=1), dict(hex="00"), dict(hex="gg"*1024),
                       dict(crc32="00000000"), dict(crc32="bad"), dict(offset=True),
                       dict(ok=False, message="Захват изменился во время чтения")]
        for update in alterations:
            with self.subTest(update=update):
                replies = copy.deepcopy(self.replies)
                replies[1].update(update)
                with self.assertRaises(la.CaptureError):
                    la.acquire(la.LogConsole(as_log(replies)))

    def test_status_integrity(self):
        for update in [dict(epoch=8), dict(divider=1), dict(flags=1, count=0, trigger_index=0),
                       dict(source=0), dict(count=1000)]:
            replies = copy.deepcopy(self.replies)
            replies[-1].update(update)
            with self.subTest(update=update), self.assertRaises(la.CaptureError):
                la.acquire(la.LogConsole(as_log(replies)))
        for update in [dict(flags=7), dict(flags=14), dict(capacity=0), dict(count=0),
                       dict(count=131073), dict(trigger_index=2048), dict(base_hz=0),
                       dict(divider=-1), dict(epoch=True), dict(source=2), dict(flags=32)]:
            with self.subTest(update=update), self.assertRaises(la.CaptureError):
                la.Descriptor.parse(status(**update))

    def test_truncation_and_parser(self):
        for text in [as_log(self.replies[:-1]), "@LA {", '@LA {"ok":1}', '@LA []']:
            with self.subTest(text=text[:30]), self.assertRaises(la.CaptureError):
                la.acquire(la.LogConsole(text))

    def test_wait_and_epoch_change(self):
        pending = status(flags=1, count=0, trigger_index=0)
        replies = [pending] + self.replies
        descriptor, data = la.acquire(la.LogConsole(as_log(replies)))
        self.assertEqual(data, self.raw)
        self.assertEqual(descriptor.epoch, 7)
        replies = [pending, status(epoch=8)]
        with self.assertRaises(la.CaptureError):
            la.acquire(la.LogConsole(as_log(replies)))
        with self.assertRaises(la.CaptureError):
            la.acquire(la.LogConsole(as_log([pending])), timeout=0.00001)

    def test_arm(self):
        class FakeConsole(la.LogConsole):
            def exchange(inner, command):
                inner.commands.append(command)
                return super().exchange(command)
        console = FakeConsole(as_log(self.replies))
        console.commands = []
        arm = (2048, 1024, 0, 65535, 5000, 0, 0, 1)
        la.acquire(console, arm)
        self.assertEqual(console.commands[0], "capture arm 2048 1024 0 65535 5000 0 0 1")
        self.assertEqual(console.commands[-1], "capture status")
        for config in [(0, 1, 0, 0, 0, 0, 0, 0), (1, 2, 0, 0, 0, 0, 0, 0),
                       (1, 1, -1, 0, 0, 0, 0, 0), (1, 1, 0, 0, 0, 1, 1, 0)]:
            with self.assertRaises(la.CaptureError):
                la.acquire(la.LogConsole(""), config)

    def test_serial_chunking_logs_and_duplicate(self):
        class Port:
            def __init__(self, chunks):
                self.chunks = iter(chunks)
                self.writes = []

            def read(self, size):
                return next(self.chunks, b"")

            def write(self, data):
                self.writes.append(data)

        reply = ("capture status\r\nI (5) pad: idle\r\n@LA " + json.dumps(status()) +
                 "\r\n\x1b[32mfabbit>\x1b[0m ").encode()
        port = Port([reply[i:i+3] for i in range(0, len(reply), 3)])
        packet = la.SerialConsole(port).exchange("capture status")
        self.assertEqual(packet, status())
        self.assertEqual(port.writes, [b"capture status\r\n"])
        duplicate = ("@LA " + json.dumps(status()) + "\n") * 2 + "fabbit>"
        with self.assertRaises(la.CaptureError):
            la.SerialConsole(Port([duplicate.encode()])).exchange("capture status")

    def test_bad_arguments_never_open_port(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(la, "open_console") as opened:
            output = str(Path(directory) / "capture.bin")
            for flags in [["--arm", "--samples", "0"], ["--timeout", "nan"],
                          ["--arm", "--rise", "1", "--fall", "1"], ["--divider=3"]]:
                with self.assertRaises(SystemExit):
                    la.main([output, "--port", "not-a-real-port", *flags])
            opened.assert_not_called()

    def test_raw_save_no_clobber(self):
        descriptor = la.Descriptor.parse(status(divider=2))
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "capture.bin"
            la.save_capture(output, descriptor, self.raw)
            self.assertEqual(output.read_bytes(), self.raw)
            metadata = json.loads(output.with_suffix(".bin.json").read_text())
            self.assertEqual(metadata["sample_rate_numerator"], 100_000_000)
            self.assertEqual(metadata["sample_rate_denominator"], 3)
            self.assertEqual(metadata["trigger_index"], 1024)
            with self.assertRaises(la.CaptureError):
                la.save_capture(output, descriptor, b"no overwrite")
            self.assertEqual(output.read_bytes(), self.raw)
            with self.assertRaises(la.CaptureError):
                la.save_capture(Path(directory) / "fractional.sr", descriptor, self.raw)
            self.assertFalse((Path(directory) / "fractional.sr").exists())
            with self.assertRaises(la.CaptureError):
                la.save_capture(Path(directory) / "truncated.bin", descriptor, self.raw[:-1])
            (Path(directory) / "existing.bin.json").write_text("user content")
            with self.assertRaises(la.CaptureError):
                la.save_capture(Path(directory) / "existing.bin", descriptor, self.raw)
            self.assertFalse((Path(directory) / "existing.bin").exists())

    def test_converter_failure_publishes_nothing(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(la.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess([], 1)
            output = Path(directory) / "capture.sr"
            with self.assertRaises(la.CaptureError):
                la.save_capture(output, la.Descriptor.parse(status()), self.raw)
            self.assertEqual(list(Path(directory).iterdir()), [])

    @unittest.skipUnless(shutil.which("sigrok-cli"), "sigrok-cli unavailable")
    def test_sr_roundtrip(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "capture.sr"
            la.save_capture(output, la.Descriptor.parse(status(divider=3)), self.raw)
            with zipfile.ZipFile(output) as archive:
                self.assertEqual(archive.read("logic-1-1"), self.raw)
                self.assertIn(b"samplerate=25 MHz", archive.read("metadata"))
            result = subprocess.run(["sigrok-cli", "-i", str(output), "-O", "binary"],
                                    capture_output=True, check=True, timeout=10)
            self.assertEqual(result.stdout, self.raw)

    @unittest.skipUnless(shutil.which("sigrok-cli"), "sigrok-cli unavailable")
    def test_uart_decode(self):
        # Independent deterministic UART stimulus, 1 Mbaud sampled at 100 MS/s.
        waveform = [1] * 300
        for byte in b"FABBIT":
            bits = [0] + [(byte >> bit) & 1 for bit in range(8)] + [1]
            for bit in bits:
                waveform += [bit] * 100
        waveform += [1] * 300
        raw = b"".join(struct.pack("<H", bit) for bit in waveform)
        descriptor, downloaded = la.acquire(la.LogConsole(as_log(transcript(raw))))
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "uart.sr"
            la.save_capture(output, descriptor, downloaded)
            result = subprocess.run(["sigrok-cli", "-i", str(output),
                                     "-P", "uart:rx=0:baudrate=1000000", "-B", "uart=rx"],
                                    capture_output=True, check=True, timeout=10)
            self.assertEqual(result.stdout, b"FABBIT")

    def test_firmware_console_transcript(self):
        root = Path(__file__).resolve().parents[2]
        executable = root / "build/firmware-tests/test_la"
        if not executable.is_file():
            self.skipTest("run make -C firmware/tests first")
        result = subprocess.run([str(executable), "--transcript"], capture_output=True,
                                text=True, check=True, timeout=10)
        descriptor, data = la.acquire(la.LogConsole(result.stdout))
        expected = b"".join(struct.pack("<H", 3976+i) for i in range(2048))
        self.assertEqual(data, expected)
        self.assertEqual(descriptor.trigger_index, 1024)


if __name__ == "__main__":
    unittest.main()
