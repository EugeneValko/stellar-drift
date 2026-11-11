"""Generate the decal sheets for the Tern (white-on-transparent masks, tinted in the shader).

    python tools/blender/tern/decals/make_decals.py

Needs Pillow. Uses the Windows font Bahnschrift (DIN-like) when present, otherwise PIL's default font.
"""
import math
import os

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
FONT = r"C:\Windows\Fonts\bahnschrift.ttf"


def font(size, bold=True):
    try:
        f = ImageFont.truetype(FONT, size)
        try:
            f.set_variation_by_name("Bold" if bold else "Regular")
        except Exception:
            pass
        return f
    except Exception:
        return ImageFont.load_default()


def canvas(w, h):
    im = Image.new("RGBA", (w, h), (255, 255, 255, 0))
    return im, ImageDraw.Draw(im)


def text_img(name, text, size=220, pad=24, spacing=0, bold=True, box=False, lines=None):
    f = font(size, bold)
    rows = lines or [text]
    tmp = ImageDraw.Draw(Image.new("RGBA", (8, 8)))
    widths, heights = [], []
    for r in rows:
        x0, y0, x1, y1 = tmp.textbbox((0, 0), r, font=f)
        widths.append(x1 - x0 + spacing * max(len(r) - 1, 0))
        heights.append(size)
    w = max(widths) + pad * 2
    lh = int(size * 1.22)
    h = lh * len(rows) + pad * 2
    im, d = canvas(w, h)
    for k, r in enumerate(rows):
        x = pad
        y = pad + k * lh
        if spacing:
            for ch in r:
                d.text((x, y), ch, font=f, fill=(255, 255, 255, 255))
                x += d.textlength(ch, font=f) + spacing
        else:
            d.text((x, y), r, font=f, fill=(255, 255, 255, 255))
    if box:
        t = max(4, size // 12)
        d.rectangle((t // 2, t // 2, w - 1 - t // 2, h - 1 - t // 2), outline=(255, 255, 255, 255), width=t)
    im.save(os.path.join(HERE, name + ".png"))
    return w / h


def emblem(name="emblem", s=1024):
    """Stylised tern: a swept bird chevron crossing a ring."""
    im, d = canvas(s, s)
    c = s / 2
    r0, r1 = s * 0.46, s * 0.40
    d.ellipse((c - r0, c - r0, c + r0, c + r0), fill=(255, 255, 255, 255))
    d.ellipse((c - r1, c - r1, c + r1, c + r1), fill=(255, 255, 255, 0))
    # bird: body dart + two long cranked wings + forked tail
    def P(pts):
        d.polygon([(c + x * s, c + y * s) for x, y in pts], fill=(255, 255, 255, 255))
    P([(0.0, -0.40), (0.045, -0.12), (0.03, 0.16), (0.0, 0.10), (-0.03, 0.16), (-0.045, -0.12)])          # body
    P([(0.04, -0.16), (0.30, -0.02), (0.49, 0.20), (0.26, 0.06), (0.04, 0.00)])                             # right wing
    P([(-0.04, -0.16), (-0.30, -0.02), (-0.49, 0.20), (-0.26, 0.06), (-0.04, 0.00)])                        # left wing
    P([(0.02, 0.06), (0.11, 0.36), (0.0, 0.17), (-0.11, 0.36), (-0.02, 0.06)])                              # forked tail
    im.save(os.path.join(HERE, name + ".png"))
    return 1.0


def caution(name="lbl_caution", s=256):
    w, h = s * 4, s
    im, d = canvas(w, h)
    m = s * 0.08
    d.polygon([(m, h - m), (s / 2, m), (s - m, h - m)], fill=(255, 255, 255, 255))
    d.polygon([(m + s * 0.17, h - m - s * 0.09), (s / 2, m + s * 0.2), (s - m - s * 0.17, h - m - s * 0.09)],
              fill=(255, 255, 255, 0))
    d.rectangle((s / 2 - s * 0.03, s * 0.42, s / 2 + s * 0.03, s * 0.68), fill=(255, 255, 255, 255))
    d.ellipse((s / 2 - s * 0.04, s * 0.72, s / 2 + s * 0.04, s * 0.80), fill=(255, 255, 255, 255))
    d.text((s * 1.1, s * 0.10), "CAUTION", font=font(int(s * 0.42)), fill=(255, 255, 255, 255))
    d.text((s * 1.1, s * 0.58), "THRUSTER EXHAUST - KEEP CLEAR", font=font(int(s * 0.17), False), fill=(255, 255, 255, 255))
    im.save(os.path.join(HERE, name + ".png"))
    return w / h


def arrow_label(name, text, s=200):
    f = font(int(s * 0.62))
    tw = int(ImageDraw.Draw(Image.new("RGBA", (8, 8))).textlength(text, font=f))
    w, h = int(s * 1.5) + tw + 30, s
    im, d = canvas(w, h)
    d.polygon([(10, h / 2), (s * 0.6, 14), (s * 0.6, h * 0.34), (s * 1.25, h * 0.34), (s * 1.25, h * 0.66), (s * 0.6, h * 0.66),
               (s * 0.6, h - 14)], fill=(255, 255, 255, 255))
    d.text((s * 1.42, s * 0.14), text, font=f, fill=(255, 255, 255, 255))
    im.save(os.path.join(HERE, name + ".png"))
    return w / h


def hazard_strip(name="hazard_strip", w=1024, h=128):
    im, d = canvas(w, h)
    step = h
    for i in range(-2, w // step + 3, 2):
        d.polygon([(i * step, h), ((i + 1) * step, h), ((i + 2) * step, 0), ((i + 1) * step, 0)], fill=(255, 255, 255, 255))
    im.save(os.path.join(HERE, name + ".png"))
    return w / h


def chevrons(name="chevrons", s=256, n=3):
    w, h = s * n, s
    im, d = canvas(w, h)
    for i in range(n):
        x = i * s
        d.polygon([(x + s * 0.1, s * 0.1), (x + s * 0.45, s * 0.1), (x + s * 0.9, s * 0.5), (x + s * 0.45, s * 0.9),
                   (x + s * 0.1, s * 0.9), (x + s * 0.55, s * 0.5)], fill=(255, 255, 255, 255))
    im.save(os.path.join(HERE, name + ".png"))
    return w / h


def main():
    out = {}
    out["txt_st7"] = text_img("txt_st7", "ST-7", 300, spacing=10)
    out["txt_tern"] = text_img("txt_tern", "TERN", 240, spacing=46)
    out["txt_07"] = text_img("txt_07", "07", 320)
    out["txt_reg"] = text_img("txt_reg", "SD-0417", 150, spacing=10, bold=False)
    out["lbl_nostep"] = text_img("lbl_nostep", "NO STEP", 120, pad=30, box=True)
    out["lbl_fuel"] = text_img("lbl_fuel", "", 78, pad=20, bold=False, box=True,
                               lines=["D-HE3 FUEL", "MAX 4.2 MPa", "GROUND BEFORE FILLING"])
    out["lbl_spec"] = text_img("lbl_spec", "", 56, pad=10, bold=False,
                               lines=["SERVICE PANEL 14-A", "FASTENER TORQUE 22 Nm", "CHECK SEAL AFTER CLOSING",
                                      "MIL-C-7707 / REV D"])
    out["lbl_spec2"] = text_img("lbl_spec2", "", 56, pad=10, bold=False,
                                lines=["HYD ACCUMULATOR", "PRESSURE 21 MPa", "RELEASE BEFORE SERVICE"])
    out["lbl_jack"] = text_img("lbl_jack", "JACK POINT", 96, pad=22, box=True)
    out["lbl_lift"] = text_img("lbl_lift", "LIFT HERE", 96, pad=22, box=True)
    out["lbl_rescue"] = arrow_label("lbl_rescue", "RESCUE")
    out["lbl_exit"] = arrow_label("lbl_exit", "EMERGENCY RELEASE")
    out["lbl_caution"] = caution()
    out["emblem"] = emblem()
    out["hazard_strip"] = hazard_strip()
    out["chevrons"] = chevrons()
    with open(os.path.join(HERE, "aspect.txt"), "w") as fh:
        for k, v in out.items():
            fh.write("%s %.5f\n" % (k, v))
    print("decals:", ", ".join(sorted(out)))


if __name__ == "__main__":
    main()
