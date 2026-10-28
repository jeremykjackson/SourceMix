#!/usr/bin/env python3
"""Renders Resources/AppIcon.icns: a glassy squircle with three EQ sliders."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

S = 1024
OUT = Path(__file__).resolve().parent.parent / "Resources"


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def render() -> Image.Image:
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    margin, radius = 100, 185
    box = (margin, margin, S - margin, S - margin)

    # Soft drop shadow
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((box[0], box[1] + 18, box[2], box[3] + 18), radius, fill=(0, 0, 0, 110))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(28)))

    # Vertical gradient body (indigo → blue → teal)
    grad = Image.new("RGBA", (S, S))
    top, mid, bot = (88, 76, 214), (40, 120, 245), (24, 196, 210)
    gd = ImageDraw.Draw(grad)
    for y in range(S):
        t = y / (S - 1)
        c = lerp(top, mid, t / 0.55) if t < 0.55 else lerp(mid, bot, (t - 0.55) / 0.45)
        gd.line([(0, y), (S, y)], fill=c + (255,))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius, fill=255)
    img.paste(grad, (0, 0), mask)

    # Glass highlight on the top half
    hl = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    hd = ImageDraw.Draw(hl)
    hd.rounded_rectangle((box[0] + 12, box[1] + 12, box[2] - 12, S // 2), radius - 12, fill=(255, 255, 255, 46))
    hl = hl.filter(ImageFilter.GaussianBlur(10))
    hl_mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(hl_mask).rounded_rectangle(box, radius, fill=255)
    img.paste(Image.alpha_composite(img, hl), (0, 0), hl_mask)

    # Rim
    rim = ImageDraw.Draw(img)
    rim.rounded_rectangle(box, radius, outline=(255, 255, 255, 90), width=5)

    # Three slider tracks with glass knobs + waveform hint
    d = ImageDraw.Draw(img)
    xs = [S * 0.33, S * 0.5, S * 0.67]
    knobs = [0.62, 0.36, 0.52]
    t0, t1 = S * 0.27, S * 0.73
    for x, k in zip(xs, knobs):
        d.rounded_rectangle((x - 26, t0, x + 26, t1), 26, fill=(255, 255, 255, 60))
        ky = t0 + (t1 - t0) * k
        d.rounded_rectangle((x - 26, ky, x + 26, t1), 26, fill=(255, 255, 255, 150))
        kshadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        ImageDraw.Draw(kshadow).rounded_rectangle((x - 58, ky - 30 + 8, x + 58, ky + 30 + 8), 30, fill=(0, 0, 0, 90))
        img.alpha_composite(kshadow.filter(ImageFilter.GaussianBlur(10)))
        d = ImageDraw.Draw(img)
        d.rounded_rectangle((x - 58, ky - 30, x + 58, ky + 30), 30, fill=(255, 255, 255, 250))
    return img


def main():
    OUT.mkdir(exist_ok=True)
    icon = render()
    icon.save(OUT / "AppIcon.png")
    icon.save(OUT / "AppIcon.icns", sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])


if __name__ == "__main__":
    main()
