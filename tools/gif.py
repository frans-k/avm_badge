#!/usr/bin/env python3
"""Convert an animated GIF into raw rgba8888 frames for AtomGL.

Stdlib only: no Pillow on this machine, so the GIF is decoded here. Frames
are sampled evenly across the animation, box-filtered down to a small
square, and written opaque, since AtomGL only takes the no-blend fast path
when alpha is 0xFF.

Frames are stored small and drawn scaled up, the same trick the shape icons
use: a 48x48 frame drawn at 3x fills 144x144 for a ninth of the bytes.

Usage:
  python3 tools/gif.py --size 48 --frames 16 --out priv/rickroll
  python3 tools/gif.py --report        # size and storage table, writes nothing
"""

import argparse
import os
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "assets", "src", "icons", "rickroll-roll.gif")


def blocks(data, pos):
    """Reads a GIF sub-block chain, returning the joined bytes and new position."""
    out = bytearray()
    while data[pos]:
        size = data[pos]
        out += data[pos + 1 : pos + 1 + size]
        pos += size + 1
    return bytes(out), pos + 1


def lzw_decode(data, min_code_size):
    clear, end = 1 << min_code_size, (1 << min_code_size) + 1
    table = [bytes([i]) for i in range(clear)] + [b"", b""]
    code_size = min_code_size + 1
    out, previous = bytearray(), None
    bits = value = 0

    for byte in data:
        value |= byte << bits
        bits += 8

        while bits >= code_size:
            code = value & ((1 << code_size) - 1)
            value >>= code_size
            bits -= code_size

            if code == clear:
                table = table[: end + 1]
                code_size = min_code_size + 1
                previous = None
                continue
            if code == end:
                return bytes(out)

            if code < len(table):
                entry = table[code]
            elif previous is not None:
                entry = previous + previous[:1]
            else:
                return bytes(out)

            out += entry
            if previous is not None:
                table.append(previous + entry[:1])
                if len(table) == (1 << code_size) and code_size < 12:
                    code_size += 1
            previous = entry

    return bytes(out)


def deinterlace(rows, height):
    order = []
    for start, step in ((0, 8), (4, 8), (2, 4), (1, 2)):
        order += list(range(start, height, step))
    out = [None] * height
    for source, target in enumerate(order):
        out[target] = rows[source]
    return out


def decode(path):
    """Yields fully composed RGB frames as (width, height, bytes)."""
    data = open(path, "rb").read()
    if data[:3] != b"GIF":
        sys.exit(f"{path}: not a GIF")

    width, height, flags = struct.unpack("<HHB", data[6:11])
    pos = 13
    global_table = b""
    if flags & 0x80:
        size = 3 * 2 ** ((flags & 7) + 1)
        global_table, pos = data[pos : pos + size], pos + size

    # Canvas is RGB; GIF transparency only ever reveals what was already there.
    canvas = bytearray(width * height * 3)
    transparent = None
    disposal = 0
    frames = []

    while pos < len(data):
        marker = data[pos]

        if marker == 0x3B:
            break

        if marker == 0x21:
            label = data[pos + 1]
            pos += 2
            if label == 0xF9:
                packed = data[pos + 1]
                disposal = (packed >> 2) & 7
                transparent = data[pos + 4] if packed & 1 else None
            _payload, pos = blocks(data, pos)
            continue

        if marker != 0x2C:
            break

        left, top, fw, fh, local = struct.unpack("<HHHHB", data[pos + 1 : pos + 10])
        pos += 10
        table = global_table
        if local & 0x80:
            size = 3 * 2 ** ((local & 7) + 1)
            table, pos = data[pos : pos + size], pos + size

        min_code_size = data[pos]
        pos += 1
        payload, pos = blocks(data, pos)
        pixels = lzw_decode(payload, min_code_size)

        rows = [pixels[y * fw : (y + 1) * fw] for y in range(fh)]
        if local & 0x40:
            rows = deinterlace(rows, fh)

        previous = bytes(canvas) if disposal == 3 else None

        for y, row in enumerate(rows):
            cy = top + y
            if cy >= height:
                break
            for x, index in enumerate(row):
                cx = left + x
                if cx >= width or index == transparent:
                    continue
                target = (cy * width + cx) * 3
                source = index * 3
                canvas[target : target + 3] = table[source : source + 3]

        frames.append((width, height, bytes(canvas)))

        if disposal == 2:
            for y in range(top, min(top + fh, height)):
                start = (y * width + left) * 3
                canvas[start : start + min(fw, width - left) * 3] = bytes(min(fw, width - left) * 3)
        elif disposal == 3 and previous is not None:
            canvas = bytearray(previous)

    return frames


def box_resize(width, height, rgb, size):
    """Averages each source block down to one pixel. No sharpening, no gamma."""
    out = bytearray(size * size * 4)

    for ty in range(size):
        y0, y1 = ty * height // size, max(ty * height // size + 1, (ty + 1) * height // size)
        for tx in range(size):
            x0, x1 = tx * width // size, max(tx * width // size + 1, (tx + 1) * width // size)
            r = g = b = count = 0
            for sy in range(y0, y1):
                row = sy * width
                for sx in range(x0, x1):
                    o = (row + sx) * 3
                    r += rgb[o]
                    g += rgb[o + 1]
                    b += rgb[o + 2]
                    count += 1
            o = (ty * size + tx) * 4
            out[o] = r // count
            out[o + 1] = g // count
            out[o + 2] = b // count
            out[o + 3] = 0xFF

    return bytes(out)


def sample_even(total, wanted):
    """Evenly spaced frame indices, so the loop stays smooth."""
    return [i * total // wanted for i in range(wanted)]


def thumbnail(width, height, rgb, edge=24):
    """A tiny greyscale version, just for comparing frames cheaply."""
    out = bytearray(edge * edge)

    for ty in range(edge):
        sy = ty * height // edge
        for tx in range(edge):
            sx = tx * width // edge
            o = (sy * width + sx) * 3
            out[ty * edge + tx] = (rgb[o] * 30 + rgb[o + 1] * 59 + rgb[o + 2] * 11) // 100

    return bytes(out)


def distance(a, b):
    return sum(abs(x - y) for x, y in zip(a, b))


def sample_distinct(frames, wanted):
    """Greedy farthest-point: repeatedly take the frame least like those chosen.

    Evenly spaced sampling of a fast dance lands on near-identical poses. This
    spreads the choice over the poses that actually differ, which for this
    animation means the ones with the arms furthest out. Chosen indices are
    returned in time order so the loop still plays forwards.
    """
    thumbs = [thumbnail(w, h, rgb) for w, h, rgb in frames]

    # Start from the frame furthest from the average, rather than frame zero.
    average = [sum(t[i] for t in thumbs) // len(thumbs) for i in range(len(thumbs[0]))]
    chosen = [max(range(len(thumbs)), key=lambda i: distance(thumbs[i], average))]

    while len(chosen) < wanted:
        best = max(
            (i for i in range(len(thumbs)) if i not in chosen),
            key=lambda i: min(distance(thumbs[i], thumbs[c]) for c in chosen),
        )
        chosen.append(best)

    return sorted(chosen)


def report(total):
    print(f"source: {total} frames\n")
    print(f"{'stored':>8}  {'scale':>5}  {'shown':>9}  {'per frame':>10}   frames -> total")
    for size, scale in ((32, 4), (36, 4), (48, 3), (64, 2), (72, 2)):
        each = size * size * 4
        shown = size * scale
        fits = "" if shown <= 156 else "  (too tall)"
        totals = "  ".join(f"{n}:{n * each // 1024}K" for n in (8, 10, 12, 16))
        print(f"{size:>4}x{size:<3}  {scale:>4}x  {shown:>4}x{shown:<4}  {each // 1024:>7} KB   {totals}{fits}")
    print("\nContent area is 320x156 between the tab rule and the help line.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--size", type=int, default=48, help="stored square edge in pixels")
    parser.add_argument("--frames", type=int, default=16, help="how many frames to keep")
    parser.add_argument("--out", default=os.path.join(ROOT, "priv", "rickroll"))
    parser.add_argument("--source", default=SOURCE)
    parser.add_argument("--report", action="store_true", help="print a size table and stop")
    parser.add_argument(
        "--select",
        choices=("distinct", "even"),
        default="distinct",
        help="distinct picks the poses that differ most; even spaces them by time",
    )
    args = parser.parse_args()

    print(f"decoding {os.path.basename(args.source)} ...")
    frames = decode(args.source)
    if not frames:
        sys.exit("no frames decoded")

    if args.report:
        report(len(frames))
        return

    os.makedirs(args.out, exist_ok=True)
    for stale in os.listdir(args.out):
        if stale.endswith(".rgba"):
            os.remove(os.path.join(args.out, stale))

    if args.select == "even":
        indices = sample_even(len(frames), args.frames)
    else:
        indices = sample_distinct(frames, args.frames)

    total = 0
    for n, index in enumerate(indices):
        width, height, rgb = frames[index]
        data = box_resize(width, height, rgb, args.size)
        name = f"frame{n:02d}@{args.size}x{args.size}.rgba"
        with open(os.path.join(args.out, name), "wb") as handle:
            handle.write(data)
        total += len(data)
        print(f"  {name}  <- source frame {index}")

    print(f"\n{args.frames} frames, {total // 1024} KB total in {args.out}")


if __name__ == "__main__":
    main()
