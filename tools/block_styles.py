#!/usr/bin/env python3
"""Block designs for GDTris: colour palettes and block styles, drawn on a board to choose from.

    python3 tools/block_styles.py    # writes /tmp/gdtris-block-options/:
                                     #   styles.png    every style, in the "balanced" palette
                                     #   palettes.png  every palette, in the "matte" style
                                     #   and each one on its own

Palettes are made in OKLCH, a colour space where equal steps of lightness look equal, so no piece
is much louder than the others (pure RGB yellow looks far brighter than pure RGB blue). The hues are
the usual ones for each piece. The preview adds a soft bloom and a vignette, as the game does.
"""

import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
OUT = Path("/tmp/gdtris-block-options")
FONT = str(ROOT / "assets" / "JetBrainsMono-SemiBold.ttf")
SS = 4  # supersampling for smooth edges
PIECES = "IJLOSTZ"

# ---- Colour ------------------------------------------------------------------------------------


def oklch(L, C, h_deg):
    """OKLCH to sRGB (0-255). Out-of-gamut colours lose chroma until they fit, keeping their hue."""
    for _ in range(40):
        a, b = C * math.cos(math.radians(h_deg)), C * math.sin(math.radians(h_deg))
        l_ = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3
        m_ = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3
        s_ = (L - 0.0894841775 * a - 1.2914855480 * b) ** 3
        lin = (4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_,
               -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_,
               -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_)
        if all(-0.001 <= v <= 1.001 for v in lin):
            break
        C *= 0.95
    srgb = [12.92 * v if v <= 0.0031308 else 1.055 * max(v, 0) ** (1 / 2.4) - 0.055 for v in lin]
    return tuple(int(round(min(max(v, 0), 1) * 255)) for v in srgb)


# Hue of each piece (the guideline colours) and the lightness each needs to sit level with the rest
HUES = {"I": 205, "J": 262, "L": 55, "O": 95, "S": 140, "T": 318, "Z": 25}
BASE_L = {"I": 0.80, "J": 0.62, "L": 0.74, "O": 0.88, "S": 0.78, "T": 0.66, "Z": 0.66}


def palette(lift=0.0, chroma=0.16):
    return {p: oklch(min(BASE_L[p] + lift, 0.95), chroma, HUES[p]) for p in PIECES}


PALETTES = {
    "current": ("Current", {"I": (62, 255, 251), "J": (95, 62, 255), "L": (252, 131, 26), "O": (252, 231, 26),
                            "S": (114, 252, 26), "T": (255, 84, 246), "Z": (252, 63, 84)}),
    "balanced": ("Balanced", palette(0.0, 0.16)),
    "vivid": ("Vivid", palette(-0.02, 0.22)),
    "soft": ("Soft", palette(0.06, 0.10)),
    "deep": ("Deep", palette(-0.1, 0.17)),
}


def mix(c, other, t):
    return tuple(int(round(a + (b - a) * t)) for a, b in zip(c, other))


def lighter(c, t):
    return mix(c, (255, 255, 255), t)


def darker(c, t):
    return mix(c, (0, 0, 0), t)


# ---- Drawing helpers ---------------------------------------------------------------------------

def gradient(w, h, top, bottom, alpha=255):
    t = np.linspace(0, 1, h)[:, None, None]
    rgb = np.array(top, float)[None, None] * (1 - t) + np.array(bottom, float)[None, None] * t
    rgb = np.repeat(rgb, w, axis=1)
    a = np.full((h, w, 1), alpha, float)
    return Image.fromarray(np.concatenate([rgb, a], axis=2).astype("uint8"), "RGBA")


def round_rect_mask(w, h, box, radius, corners=(True, True, True, True)):
    m = Image.new("L", (w, h), 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255, corners=corners)
    return m


def paste_masked(img, layer, mask):
    img.alpha_composite(Image.composite(layer, Image.new("RGBA", layer.size, (0, 0, 0, 0)), mask))


# ---- Styles ------------------------------------------------------------------------------------
# Each draws one cell, edge to edge: blocks touch, with no gaps between them, and are told apart by
# fine light and dark edges instead. `same` = which neighbours (up, down, left, right) are the same
# piece; only the connected style uses it. Sizes are fractions of the cell, so they work at any size.


def edges(img, s, top=None, left=None, bottom=None, right=None, width=0.03):
    """Fine lines along the cell's sides, each (colour, alpha) or None."""
    w = max(1, int(s * width))
    d = ImageDraw.Draw(img)
    for side, spec in (("top", top), ("left", left), ("bottom", bottom), ("right", right)):
        if spec is None:
            continue
        layer = Image.new("RGBA", (s, s), (0, 0, 0, 0))
        ld = ImageDraw.Draw(layer)
        box = {"top": [0, 0, s, w], "left": [0, 0, w, s], "bottom": [0, s - w, s, s], "right": [s - w, 0, s, s]}[side]
        ld.rectangle(box, fill=spec[0] + (spec[1],))
        img.alpha_composite(layer)


def style_matte(c, s, same):
    """Matte: a quiet top-to-bottom shade, a fine light edge above and a fine dark edge below."""
    img = gradient(s, s, lighter(c, 0.1), darker(c, 0.1))
    edges(img, s, top=((255, 255, 255), 80), left=((255, 255, 255), 35),
          bottom=(darker(c, 0.5), 150), right=(darker(c, 0.5), 90))
    return img


def style_lit(c, s, same):
    """Lit: glows from inside, brightest in the upper middle, as if it were a light."""
    y, x = np.mgrid[0:s, 0:s] / s
    d = np.sqrt((x - 0.5) ** 2 + (y - 0.4) ** 2 * 1.3)
    t = np.clip(d / 0.7, 0, 1)[..., None] ** 1.4
    rgb = np.array(lighter(c, 0.35), float) * (1 - t) + np.array(darker(c, 0.2), float) * t
    img = Image.fromarray(np.concatenate([rgb, np.full((s, s, 1), 255)], axis=2).astype("uint8"), "RGBA")
    edges(img, s, top=(lighter(c, 0.6), 90), left=(lighter(c, 0.6), 50),
          bottom=(darker(c, 0.55), 140), right=(darker(c, 0.55), 100), width=0.025)
    return img


def style_frosted(c, s, same):
    """Frosted glass: the colour a little see-through, a sheen at the top and fine bright edges."""
    img = gradient(s, s, lighter(c, 0.16), c, alpha=220)
    sheen = np.zeros((s, s, 4), "uint8")
    sheen[..., :3] = 255
    sheen[..., 3] = (np.clip(1 - np.linspace(0, 1, s) / 0.45, 0, 1)[:, None] * 50).astype("uint8")
    img.alpha_composite(Image.fromarray(sheen))
    edges(img, s, top=(lighter(c, 0.7), 140), left=(lighter(c, 0.6), 90),
          bottom=(darker(c, 0.45), 120), right=(darker(c, 0.45), 90), width=0.025)
    return img


def style_keycap(c, s, same):
    """Keycap: a rounded top face standing on a square base that fills the cell, like a key."""
    img = Image.new("RGBA", (s, s), darker(c, 0.3) + (255,))
    face = [s * 0.07, s * 0.05, s * 0.93, s * 0.85]
    paste_masked(img, gradient(s, s, lighter(c, 0.14), mix(c, darker(c, 0.05), 0.5)), round_rect_mask(s, s, face, s * 0.14))
    edge = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle(face, radius=s * 0.14, outline=(255, 255, 255, 60), width=int(s * 0.02))
    top_only = Image.new("L", (s, s), 0)
    ImageDraw.Draw(top_only).rectangle([0, 0, s, s * 0.4], fill=255)
    paste_masked(img, edge, top_only)
    edges(img, s, bottom=(darker(c, 0.6), 160), right=(darker(c, 0.55), 110), width=0.025)
    return img


def style_connected(c, s, same):
    """Connected: the cells of one piece join into one shape, with no line inside it. Where the
    piece ends there is a fine dark line against its neighbour, a light edge on top and a deeper
    shade along the bottom (TETR.IO's idea, drawn quieter and with no gaps)."""
    up, down, left, right = same
    # flat, as in the game: a shade inside each cell would show a seam where the cells meet
    img = Image.new("RGBA", (s, s), c + (255,))
    bevel = 0.09
    edges(img, s, top=None if up else (lighter(c, 0.45), 170), left=None if left else (lighter(c, 0.3), 110),
          bottom=None if down else (darker(c, 0.3), 170), right=None if right else (darker(c, 0.3), 120), width=bevel)
    edges(img, s, top=None if up else (darker(c, 0.65), 230), left=None if left else (darker(c, 0.65), 230),
          bottom=None if down else (darker(c, 0.65), 230), right=None if right else (darker(c, 0.65), 230), width=0.025)
    return img


STYLES = {
    "matte": ("Matte", style_matte),
    "lit": ("Lit", style_lit),
    "frosted": ("Frosted", style_frosted),
    "keycap": ("Keycap", style_keycap),
    "connected": ("Connected", style_connected),
}

# ---- A board -----------------------------------------------------------------------------------

SHAPES = {"I": [(0, 1), (1, 1), (2, 1), (3, 1)], "J": [(0, 0), (0, 1), (1, 1), (2, 1)], "L": [(2, 0), (0, 1), (1, 1), (2, 1)],
          "O": [(0, 0), (1, 0), (0, 1), (1, 1)], "S": [(1, 0), (2, 0), (0, 1), (1, 1)], "T": [(1, 0), (0, 1), (1, 1), (2, 1)],
          "Z": [(0, 0), (1, 0), (1, 1), (2, 1)]}


def rotations(kind):
    cells, out = SHAPES[kind], []
    for _ in range(4):
        xs, ys = [p[0] for p in cells], [p[1] for p in cells]
        norm = sorted((x - min(xs), y - min(ys)) for x, y in cells)
        if norm not in out:
            out.append(norm)
        cells = [(-y, x) for x, y in cells]
    return out


def build_stack(width=10, height=14, sequence="LJSZOITJLSZTOIJS"):
    """A plausible stack: each piece goes where it leaves the fewest holes and the flattest top,
    with the right column kept open as a well, as a player would."""
    grid = [[None] * width for _ in range(height)]
    for pid, kind in enumerate(sequence):
        best = None
        for shape in rotations(kind):
            w = max(x for x, _ in shape) + 1
            for x0 in range(width - w + 1):
                y0 = 0
                while all(y0 + y + 1 < height and grid[y0 + y + 1][x0 + x] is None for x, y in shape):
                    y0 += 1
                if any(grid[y0 + y][x0 + x] is not None for x, y in shape):
                    continue
                trial = [row[:] for row in grid]
                for x, y in shape:
                    trial[y0 + y][x0 + x] = (kind, pid)
                tops = [next((r for r in range(height) if trial[r][c] is not None), height) for c in range(width)]
                holes = sum(1 for c in range(width) for r in range(tops[c], height) if trial[r][c] is None)
                heights = [height - t for t in tops]
                score = holes * 6 + sum(heights[:-1]) + sum(abs(heights[c] - heights[c + 1]) for c in range(width - 2)) * 0.6 + heights[-1] * 8
                if best is None or score < best[0]:
                    best = (score, trial)
        grid = best[1]
    return grid


def cell_image(style, colour, size, same):
    big = STYLES[style][1](colour, size * SS, same)
    return big.resize((size, size), Image.LANCZOS)


def board(style, colours, grid, background, title):
    cell = 40
    rows, cols = len(grid), len(grid[0])
    img = background.copy()
    bx, by = 60, 86
    img.alpha_composite(Image.new("RGBA", (cols * cell, rows * cell), (4, 7, 6, 175)), (bx, by))
    lines = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ld = ImageDraw.Draw(lines)
    for r in range(rows + 1):
        ld.line([(bx, by + r * cell), (bx + cols * cell, by + r * cell)], fill=(255, 255, 255, 13))
    for c in range(cols + 1):
        ld.line([(bx + c * cell, by), (bx + c * cell, by + rows * cell)], fill=(255, 255, 255, 13))
    ld.rectangle([bx - 2, by - 2, bx + cols * cell + 1, by + rows * cell + 1], outline=(158, 230, 199, 150), width=2)
    img.alpha_composite(lines)

    cache = {}

    def put(kind, x, y, same=(False, False, False, False), size=cell, ghost=False):
        key = (kind, same, size, ghost)
        if key not in cache:
            t = cell_image(style, colours[kind], size, same)
            if ghost:
                a = np.array(t)
                a[..., 3] = (a[..., 3] * 0.2).astype("uint8")
                a[..., :3] = 255
                t = Image.fromarray(a)
            cache[key] = t
        img.alpha_composite(cache[key], (x, y))

    def neighbours(cells, x, y):
        return tuple((x + dx, y + dy) in cells for dx, dy in [(0, -1), (0, 1), (-1, 0), (1, 0)])

    fall = [(4, 1), (3, 2), (4, 2), (5, 2)]
    drop = 0
    while all(y + drop + 1 < rows and grid[y + drop + 1][x] is None for x, y in fall):
        drop += 1
    for x, y in fall:
        put("T", bx + x * cell, by + (y + drop) * cell, neighbours(set(fall), x, y), ghost=True)
    for r in range(rows):
        for c in range(cols):
            if grid[r][c] is not None:
                kind, pid = grid[r][c]
                same = tuple(0 <= rr < rows and 0 <= cc < cols and grid[rr][cc] is not None and grid[rr][cc][1] == pid
                             for rr, cc in [(r - 1, c), (r + 1, c), (r, c - 1), (r, c + 1)])
                put(kind, bx + c * cell, by + r * cell, same)
    for x, y in fall:
        put("T", bx + x * cell, by + y * cell, neighbours(set(fall), x, y))

    small = 30
    qx, qy = bx + cols * cell + 50, by + 40
    font = ImageFont.truetype(FONT, 20)
    ImageDraw.Draw(img).text((qx, by), "NEXT", font=font, fill=(235, 242, 240, 255))
    for i, kind in enumerate("IOSZJL"):
        shape = SHAPES[kind]
        for x, y in shape:
            put(kind, qx + x * small, qy + i * 3 * small + y * small, neighbours(set(shape), x, y), size=small)

    # The game's look: a soft bloom from the bright parts, then a vignette
    arr = np.array(img).astype(float)
    luma = arr[..., :3].mean(axis=2, keepdims=True) / 255
    bright = Image.fromarray(np.clip(arr[..., :3] * np.clip((luma - 0.45) * 2.5, 0, 1), 0, 255).astype("uint8"))
    glow = np.array(bright.filter(ImageFilter.GaussianBlur(10))).astype(float)
    out = arr[..., :3] + glow * 0.35
    h, w = out.shape[:2]
    yy, xx = np.mgrid[0:h, 0:w]
    vig = 1 - 0.45 * np.clip((np.hypot((xx - w / 2) / w, (yy - h / 2) / h) - 0.25) / 0.45, 0, 1)
    out = np.clip(out * vig[..., None], 0, 255).astype("uint8")
    img = Image.fromarray(out).convert("RGBA")
    ImageDraw.Draw(img).text((bx, 30), title, font=ImageFont.truetype(FONT, 28), fill=(158, 230, 199, 255))
    return img.convert("RGB")


def swatches(colours, width):
    """A strip of the seven colours with their hex codes."""
    img = Image.new("RGB", (width, 70), (10, 14, 13))
    d = ImageDraw.Draw(img)
    font = ImageFont.truetype(FONT, 14)
    w = width // 7
    for i, p in enumerate(PIECES):
        c = colours[p]
        d.rounded_rectangle([i * w + 8, 8, i * w + w - 8, 40], radius=6, fill=c)
        d.text((i * w + 10, 46), f"{p} #{c[0]:02x}{c[1]:02x}{c[2]:02x}", font=font, fill=(170, 180, 176))
    return img


def sheet(images, cols):
    w, h = images[0].size
    out = Image.new("RGB", (cols * w, ((len(images) + cols - 1) // cols) * h), (0, 0, 0))
    for i, im in enumerate(images):
        out.paste(im, ((i % cols) * w, (i // cols) * h))
    return out


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("*.png"):
        old.unlink()
    w, h = 760, 740
    photo = Image.open(ROOT / "assets" / "bg.jpg").convert("RGB")
    scale = max(w / photo.width, h / photo.height)
    photo = photo.resize((int(photo.width * scale) + 1, int(photo.height * scale) + 1), Image.LANCZOS)
    left, top = (photo.width - w) // 2, (photo.height - h) // 2
    background = Image.fromarray((np.array(photo.crop((left, top, left + w, top + h))) * 0.42).astype("uint8")).convert("RGBA")
    grid = build_stack()

    styles = []
    for key, (name, _) in STYLES.items():
        im = board(key, PALETTES["balanced"][1], grid, background, name.upper())
        swatch = swatches(PALETTES["balanced"][1], w)
        full = Image.new("RGB", (w, h + 70))
        full.paste(im, (0, 0))
        full.paste(swatch, (0, h))
        full.save(OUT / f"style-{key}.png")
        styles.append(full)
    sheet(styles, 5).save(OUT / "styles.png")

    palettes = []
    for key, (name, colours) in PALETTES.items():
        im = board("matte", colours, grid, background, f"{name.upper()} COLOURS")
        full = Image.new("RGB", (w, h + 70))
        full.paste(im, (0, 0))
        full.paste(swatches(colours, w), (0, h))
        full.save(OUT / f"palette-{key}.png")
        palettes.append(full)
    sheet(palettes, 5).save(OUT / "palettes.png")
    print(f"wrote styles.png, palettes.png and {len(styles) + len(palettes)} single previews to {OUT}")


if __name__ == "__main__":
    main()
