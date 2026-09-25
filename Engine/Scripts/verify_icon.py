#!/usr/bin/env python3
"""Validate the icon PNG without ImageMagick or third-party Python packages."""

import struct
import sys
import zlib


def paeth(left: int, up: int, upper_left: int) -> int:
    estimate = left + up - upper_left
    distances = (abs(estimate - left), abs(estimate - up), abs(estimate - upper_left))
    return (left, up, upper_left)[distances.index(min(distances))]


def inspect(path: str) -> tuple[str, int, bool]:
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")

    offset = 8
    width = height = bit_depth = color_type = None
    compressed = bytearray()
    palette = b""
    transparency = b""
    while offset < len(data):
        if offset + 12 > len(data):
            raise ValueError("truncated PNG chunk")
        length = struct.unpack_from(">I", data, offset)[0]
        kind = data[offset + 4 : offset + 8]
        start = offset + 8
        end = start + length
        if end + 4 > len(data):
            raise ValueError("truncated PNG payload")
        payload = data[start:end]
        if kind == b"IHDR":
            width, height, bit_depth, color_type, compression, filtering, interlace = struct.unpack(
                ">IIBBBBB", payload
            )
            if compression != 0 or filtering != 0 or interlace != 0:
                raise ValueError("unsupported PNG encoding")
        elif kind == b"PLTE":
            palette = payload
        elif kind == b"tRNS":
            transparency = payload
        elif kind == b"IDAT":
            compressed.extend(payload)
        elif kind == b"IEND":
            break
        offset = end + 4

    if not width or not height:
        raise ValueError("invalid PNG dimensions")
    if color_type == 3:
        if bit_depth not in (1, 2, 4, 8) or not palette or len(palette) % 3:
            raise ValueError("expected a valid indexed-color PNG")
        bytes_per_pixel = 1
        row_bytes = (width * bit_depth + 7) // 8
    elif color_type in (2, 6) and bit_depth == 8:
        bytes_per_pixel = 3 if color_type == 2 else 4
        row_bytes = width * bytes_per_pixel
    else:
        raise ValueError("expected 8-bit RGB/RGBA or indexed-color PNG")
    raw = zlib.decompress(compressed)
    expected = height * (row_bytes + 1)
    if len(raw) != expected:
        raise ValueError("unexpected decompressed PNG length")

    colors: set[tuple[int, int, int]] = set()
    opaque = True
    previous = bytearray(row_bytes)
    cursor = 0
    for _ in range(height):
        filter_kind = raw[cursor]
        cursor += 1
        row = bytearray(raw[cursor : cursor + row_bytes])
        cursor += row_bytes
        if filter_kind == 1:
            for i in range(bytes_per_pixel, row_bytes):
                row[i] = (row[i] + row[i - bytes_per_pixel]) & 0xFF
        elif filter_kind == 2:
            for i in range(row_bytes):
                row[i] = (row[i] + previous[i]) & 0xFF
        elif filter_kind == 3:
            for i in range(row_bytes):
                left = row[i - bytes_per_pixel] if i >= bytes_per_pixel else 0
                row[i] = (row[i] + ((left + previous[i]) // 2)) & 0xFF
        elif filter_kind == 4:
            for i in range(row_bytes):
                left = row[i - bytes_per_pixel] if i >= bytes_per_pixel else 0
                up = previous[i]
                upper_left = previous[i - bytes_per_pixel] if i >= bytes_per_pixel else 0
                row[i] = (row[i] + paeth(left, up, upper_left)) & 0xFF
        elif filter_kind != 0:
            raise ValueError(f"unsupported PNG filter {filter_kind}")

        if color_type == 3:
            entries_per_byte = 8 // bit_depth
            mask = (1 << bit_depth) - 1
            for x in range(width):
                shift = 8 - bit_depth * ((x % entries_per_byte) + 1)
                palette_index = (row[x // entries_per_byte] >> shift) & mask
                palette_offset = palette_index * 3
                if palette_offset + 2 >= len(palette):
                    raise ValueError("palette index outside PLTE")
                colors.add(tuple(palette[palette_offset : palette_offset + 3]))
                if palette_index < len(transparency) and transparency[palette_index] != 255:
                    opaque = False
                if len(colors) > 4:
                    return f"{width}x{height}", len(colors), opaque
        else:
            step = bytes_per_pixel
            for i in range(0, row_bytes, step):
                red, green, blue = row[i], row[i + 1], row[i + 2]
                colors.add((red, green, blue))
                if step == 4 and row[i + 3] != 255:
                    opaque = False
                if len(colors) > 4:
                    return f"{width}x{height}", len(colors), opaque
        previous = row

    return f"{width}x{height}", len(colors), opaque


if __name__ == "__main__":
    try:
        dimensions, color_count, is_opaque = inspect(sys.argv[1])
    except Exception as error:  # A malformed image is a failed structural check.
        print(f"icon validation error: {error}", file=sys.stderr)
        raise SystemExit(1)
    print(f"{dimensions}\t{color_count}\t{str(is_opaque).lower()}")
