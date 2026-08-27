"""Release icon invariants; no Figma/network or imaging-library dependency."""
import struct
import unittest
import zlib
from unittest.mock import patch

from scripts.check_icon import ROOT, check_assets, check_icns, check_svg


class IconAssetsTest(unittest.TestCase):
    def test_committed_assets_are_safe_and_complete(self):
        check_assets()

    def test_accidental_opaque_export_background_is_rejected(self):
        def chunk(tag, data):
            return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data))
        opaque = (b'\x89PNG\r\n\x1a\n'
                  + chunk(b'IHDR', struct.pack('>IIBBBBB', 1024, 1024, 8, 6, 0, 0, 0))
                  + chunk(b'IDAT', zlib.compress((b'\x00' + b'\xe5\xe5\xe5\xff' * 1024) * 1024))
                  + chunk(b'IEND', b''))
        read = type(ROOT).read_bytes
        def read_export(path):
            return opaque if path.name == 'icon_1024.png' else read(path)
        with patch.object(type(ROOT), 'read_bytes', read_export), self.assertRaisesRegex(ValueError, 'transparent'):
            check_assets()

    def test_active_content_external_resources_and_bitmaps_are_rejected(self):
        for payload in ('<script>alert(1)</script>', '<image href="https://example.invalid/x"/>',
                        '<image href="data:image/png;base64,AA=="/>',
                        '<path onload="alert(1)"/>', '<path style="fill:url(https://example.invalid)"/>',
                        '<path fill="url(https://example.invalid)"/>', '<foreignObject/>'):
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                check_svg(f'<svg xmlns="http://www.w3.org/2000/svg">{payload}</svg>'.encode())

    def test_incomplete_or_corrupted_icns_is_rejected(self):
        data = (ROOT / 'assets/icon.icns').read_bytes()
        with self.assertRaises(ValueError):
            check_icns(data[:-1])
        chunks = check_icns(data)
        body = b''.join(tag + struct.pack('>I', len(value) + 8) + value
                        for tag, value in chunks.items() if tag != b'ic12')
        with self.assertRaisesRegex(ValueError, 'ic12'):
            check_icns(b'icns' + struct.pack('>I', len(body) + 8) + body)


if __name__ == '__main__':
    unittest.main()
