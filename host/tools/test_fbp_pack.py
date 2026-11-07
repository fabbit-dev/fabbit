"""Synthetic RETRO profile packaging; never reads a board or real bitstream."""
import contextlib
import importlib.util
import io
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
import zlib


spec = importlib.util.spec_from_file_location("fbp_pack", Path(__file__).with_name("fbp_pack.py"))
packer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packer)


class RetroPackageTests(unittest.TestCase):
    def package(self, payload, xilinx_header=False):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "synthetic.bit"
            output = Path(directory) / "retro.fbp"
            container = payload
            if xilinx_header:
                container = (b"\x00\x09" + bytes(9) + b"\x00\x01" +
                             b"a\x00\x05test\x00e" + struct.pack(">I", len(payload)) + payload)
            source.write_bytes(container)
            argv = ["fbp_pack.py", str(source), str(output), "--id", "4", "--name", "RETRO"]
            with patch.object(sys, "argv", argv), contextlib.redirect_stdout(io.StringIO()):
                packer.main()
            data = output.read_bytes()
        header, image = data[:64], data[64:]
        magic, profile, flags, version, length, crc, name, cor0 = struct.unpack(
            "<4sHBBII32sI8x", header[:60])
        self.assertEqual((magic, profile, flags, version), (b"FBP1", 4, 0, 1))
        self.assertEqual(length, len(image))
        self.assertEqual(crc, zlib.crc32(image))
        self.assertEqual(name.rstrip(b"\0"), b"RETRO")
        self.assertEqual(struct.unpack("<I", header[60:])[0], zlib.crc32(header[:60]))
        self.assertEqual(cor0, packer.read_cor0(image))
        return image

    def test_vivado_crc_stream_is_byte_exact(self):
        payload = (b"\xff" * 8 + packer.SYNC + struct.pack(">II", packer.COR0_WRITE, 0x02423FE5) +
                   struct.pack(">II", packer.CRC_WRITE, 0x12345678))
        self.assertEqual(self.package(payload, xilinx_header=True), payload)

    def test_raw_stream_changes_only_clock_rate(self):
        old_cor0 = 0x00003FE5
        payload = packer.SYNC + struct.pack(">II", packer.COR0_WRITE, old_cor0) + bytes(32)
        image = self.package(payload)
        expected = bytearray(payload)
        struct.pack_into(">I", expected, 8,
                         (old_cor0 & ~packer.OSCFSEL_MASK) | (0x02423FE5 & packer.OSCFSEL_MASK))
        self.assertEqual(image, expected)


if __name__ == "__main__":
    unittest.main()
