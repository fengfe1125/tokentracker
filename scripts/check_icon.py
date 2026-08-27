"""Offline checks for the small, deliberately restricted icon asset format."""
from pathlib import Path
import re
import struct
import xml.etree.ElementTree as ET
import zlib

ROOT = Path(__file__).resolve().parents[1]
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
ICNS_PNG_SIZES = {b"ic11": 32, b"ic12": 64, b"ic07": 128,
                  b"ic08": 256, b"ic13": 256, b"ic09": 512,
                  b"ic14": 512, b"ic10": 1024}


def check_svg(data):
    if b"<!" in data:
        raise ValueError("SVG declarations/entities are not allowed")
    root = ET.fromstring(data)
    namespace = "{http://www.w3.org/2000/svg}"
    allowed = {"width", "height", "viewBox", "fill", "stroke", "d",
               "stroke-width", "stroke-linecap", "stroke-linejoin"}
    if root.tag != namespace + "svg":
        raise ValueError("Expected SVG root")
    for node in root.iter():
        if node.tag not in {namespace + "svg", namespace + "path", namespace + "g"}:
            raise ValueError("Only editable vector paths/groups are allowed")
        if set(node.attrib) - allowed:
            raise ValueError("Unexpected SVG attribute (scripts/links/styles are forbidden)")
        for attr in ("fill", "stroke"):
            if attr in node.attrib and not re.fullmatch(r"none|#[0-9A-Fa-f]{6}", node.attrib[attr]):
                raise ValueError("Only flat colors are allowed")
        if node.text and node.text.strip():
            raise ValueError("Icon must not contain text")
    return root


def png_rows(data):
    """Decode our 8-bit non-interlaced RGBA exports using only the stdlib."""
    if not data.startswith(PNG_SIGNATURE):
        raise ValueError("Invalid PNG signature")
    chunks, pos = {}, 8
    while pos < len(data):
        size, tag = struct.unpack(">I4s", data[pos:pos + 8])
        payload = data[pos + 8:pos + 8 + size]
        crc = struct.unpack(">I", data[pos + 8 + size:pos + 12 + size])[0]
        if zlib.crc32(tag + payload) != crc:
            raise ValueError("Invalid PNG CRC")
        chunks.setdefault(tag, []).append(payload)
        pos += size + 12
    width, height, depth, color, comp, filt, interlace = struct.unpack(">IIBBBBB", chunks[b"IHDR"][0])
    if (depth, color, comp, filt, interlace) != (8, 6, 0, 0, 0):
        raise ValueError("Expected non-interlaced 8-bit RGBA PNG")
    raw = zlib.decompress(b"".join(chunks[b"IDAT"]))
    stride = width * 4
    if len(raw) != height * (stride + 1):
        raise ValueError("Invalid PNG pixel length")
    rows, previous = [], bytearray(stride)
    for y in range(height):
        start = y * (stride + 1)
        kind, row = raw[start], bytearray(raw[start + 1:start + stride + 1])
        if kind not in range(5):
            raise ValueError("Invalid PNG filter")
        for x in range(stride):
            a = row[x - 4] if x >= 4 else 0
            b = previous[x]
            c = previous[x - 4] if x >= 4 else 0
            if kind == 1:
                predictor = a
            elif kind == 2:
                predictor = b
            elif kind == 3:
                predictor = (a + b) // 2
            elif kind == 4:
                p = a + b - c
                distances = (abs(p - a), abs(p - b), abs(p - c))
                predictor = (a, b, c)[distances.index(min(distances))]
            else:
                predictor = 0
            row[x] = (row[x] + predictor) & 255
        rows.append(row)
        previous = row
    return width, height, rows


def check_icns(data):
    magic, total = struct.unpack(">4sI", data[:8])
    if magic != b"icns" or total != len(data):
        raise ValueError("Invalid ICNS header")
    chunks, pos = {}, 8
    while pos < total:
        tag, size = struct.unpack(">4sI", data[pos:pos + 8])
        if size < 8 or pos + size > total or tag in chunks:
            raise ValueError("Invalid ICNS chunk")
        chunks[tag] = data[pos + 8:pos + size]
        pos += size
    if not ({b"ic04", b"icp4"} & chunks.keys() and {b"ic05", b"icp5"} & chunks.keys()):
        raise ValueError("Missing 16/32px ICNS representations")
    for tag, size in ICNS_PNG_SIZES.items():
        payload = chunks.get(tag, b"")
        if not payload.startswith(PNG_SIGNATURE) or struct.unpack(">II", payload[16:24]) != (size, size):
            raise ValueError(f"Missing/incorrect ICNS representation: {tag!r}")
    return chunks


def check_assets(root=ROOT):
    for path in (root / "assets/icon.svg", root / "app/web/brand.svg"):
        check_svg(path.read_bytes())
    width, height, rows = png_rows((root / "assets/icon_1024.png").read_bytes())
    if (width, height) != (1024, 1024):
        raise ValueError("App PNG must be 1024 × 1024")
    if any(rows[0][3::4]) or any(rows[-1][3::4]) or any(row[3] or row[-1] for row in rows):
        raise ValueError("App PNG outer edges must be transparent")
    if rows[512][512 * 4 + 3] != 255:
        raise ValueError("Missing opaque App icon plate")
    chunks = check_icns((root / "assets/icon.icns").read_bytes())
    if png_rows(chunks[b"ic10"])[2] != rows:
        raise ValueError("ICNS 1024px image differs from the approved PNG; rebuild ICNS")


if __name__ == "__main__":
    check_assets()
    print("Icon OK: safe vectors, 1024px RGBA with transparent edges, complete 1×/2× ICNS.")
