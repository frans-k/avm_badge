#!/usr/bin/env python3
"""Turns the share page's line art into rectangles, for `Badge.Page.Share`.

The art is a diagram of straight lines, and as a baked icon it cost 74 KB of flash
(a 9,216 byte mask, once for each tint). As rectangles it is a list of a few
hundred bytes, drawn in the skin's glyph colour. Pixels at least half opaque are
drawn, the rest are not, so the few anti-aliased pixels of its curves become square.

    python3 tools/art_rects.py assets/src/art/badge-share.png

prints the Elixir list to paste into `@art_rects`. Greedy: each rectangle takes the
next unused pixel in reading order, is grown to the right as far as it can, then
downwards as far as the whole width allows.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import icons  # noqa: E402  (this folder's tools/icons.py)

THRESHOLD = 128


def rectangles(path):
    width, height, pixels = icons.decode_png(path)
    mask = icons.to_mask(pixels)
    on = [[mask[y * width + x] >= THRESHOLD for x in range(width)] for y in range(height)]
    used = [[False] * width for _ in range(height)]
    rects = []

    for y in range(height):
        for x in range(width):
            if not on[y][x] or used[y][x]:
                continue

            w = 1
            while x + w < width and on[y][x + w] and not used[y][x + w]:
                w += 1

            h = 1
            while y + h < height and all(
                on[y + h][x + i] and not used[y + h][x + i] for i in range(w)
            ):
                h += 1

            for j in range(h):
                for i in range(w):
                    used[y + j][x + i] = True

            rects.append((x, y, w, h))

    return width, height, rects


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)

    width, height, rects = rectangles(sys.argv[1])
    print(f"# {width} x {height}, {len(rects)} rectangles")
    print("@art_rects [")
    print(",\n".join(f"  {{{x}, {y}, {w}, {h}}}" for x, y, w, h in rects))
    print("]")


if __name__ == "__main__":
    main()
