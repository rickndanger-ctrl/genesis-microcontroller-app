"""Build the app icon from the Blender-rendered deck pieces.

Run: python3 design/build_app_icon.py [output.png]

Four controls from the deck (the chat knob and three lit keys) on the deck's
pearl surface, edge to edge: iOS rounds the corners itself. The pieces are the same renders the app draws, produced by
build_deck.py, so the icon always matches the controller. Needs Pillow.
"""
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageChops

ROOT = Path(__file__).resolve().parent
RESOURCES = ROOT.parent / "ios/Resources"
OUTPUT = Path(sys.argv[1]) if len(sys.argv) > 1 else RESOURCES / "Assets.xcassets/AppIcon.appiconset/icon1024.png"
SIZE, SCALE = 1024, 2            # drawn at twice the size, then reduced
W = SIZE * SCALE
BLUE, PURPLE, PINK, GREEN = (52, 120, 246), (155, 92, 246), (240, 82, 156), (48, 199, 120)   # slots 1, 2, 3 and 5


def piece(name, size):
    return Image.open(RESOURCES / f"{name}.png").convert("RGBA").resize((size, size), Image.LANCZOS)


def lit(body, glow, color, strength):
    """The body with its LED showing through in `color`."""
    out = body.copy()
    alpha = glow.getchannel("A").point(lambda a: int(a * strength))
    tint = Image.new("RGBA", body.size, color + (0,))
    tint.putalpha(alpha)
    out = Image.alpha_composite(out, tint)
    # A white-hot centre where the LED sits.
    core = glow.getchannel("A").point(lambda a: max(0, a - 205) * 4)
    hot = Image.new("RGBA", body.size, (255, 255, 255, 0))
    hot.putalpha(core.filter(ImageFilter.GaussianBlur(body.size[0] / 40)))
    return Image.alpha_composite(out, hot)


def halo(size, color, strength):
    """Soft coloured light spilling onto the plate around a control."""
    layer = Image.new("RGBA", (size, size), color + (0,))
    mask = Image.new("L", (size, size), 0)
    inset = size * 0.25
    ImageDraw.Draw(mask).rounded_rectangle((inset, inset, size - inset, size - inset * 0.86), radius=size * 0.09, fill=int(255 * strength))
    layer.putalpha(mask.filter(ImageFilter.GaussianBlur(size * 0.055)))
    return layer


# Pearl background, lighter at the top.
canvas = Image.new("RGBA", (W, W))
top, bottom = (247, 249, 252), (218, 224, 234)
draw = ImageDraw.Draw(canvas)
for y in range(W):
    t = y / (W - 1)
    draw.line([(0, y), (W, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,))

cell = int(W * 0.56)             # each piece's image; the control itself fills about 60% of it
left, right, upper, lower = int(W * 0.285), int(W * 0.715), int(W * 0.285), int(W * 0.715)
cap, cap_glow = piece("DeckCapUp", cell), piece("DeckCapUpGlow", cell)
knob, knob_glow = piece("DeckKnobSnow", cell), piece("DeckKnobSnowGlow", cell)


def place(image, cx, cy):
    global canvas
    layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    layer.paste(image, (cx - image.size[0] // 2, cy - image.size[1] // 2))
    canvas = Image.alpha_composite(canvas, layer)


for color, cx, cy in ((PURPLE, right, upper), (PINK, left, lower), (GREEN, right, lower)):
    place(halo(cell, color, .34), cx, cy)
place(halo(cell, BLUE, .26), left, upper)
place(lit(knob, knob_glow, BLUE, .42), left, upper + int(W * 0.006))
place(lit(cap, cap_glow, PURPLE, .62), right, upper)
place(lit(cap, cap_glow, PINK, .62), left, lower)
place(lit(cap, cap_glow, GREEN, .62), right, lower)

OUTPUT.parent.mkdir(parents=True, exist_ok=True)
canvas.convert("RGB").resize((SIZE, SIZE), Image.LANCZOS).save(OUTPUT, "PNG")
print("APP_ICON", OUTPUT)
