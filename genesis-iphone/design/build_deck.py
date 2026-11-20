"""Genesis controller, modelled as a real 3D keyboard. Blender 5.2+.

Run: blender -b --factory-startup --python design/build_deck.py

The deck is seen through an orthographic camera tilted 24 degrees toward the
viewer, so every key shows its front wall and stands off the plate. Because
the projection is orthographic, one keycap render is correct at every grid
position, which lets the app lay the keys out itself and resize them.

Each control is rendered twice:
  * a beauty pass under studio light, on a transparent film with its shadow;
  * an LED pass with the studio dark and a white LED under the control.
The LED pass becomes a white image whose alpha is the light's intensity. The
app tints that mask with the slot color and fades it with the glow level, so
one neutral render serves every color and brightness.

Outputs go to ../ios/Resources (Deck*.png) and deck-metrics.json records the
pixel geometry the app uses to place labels and slice the images.

Environment: GENESIS_SAMPLES (default 160), GENESIS_ONLY (comma-separated
names from shell, cap, knob, puck; "scene" saves the .blend without
rendering), GENESIS_RENDER_DEVICE=METAL.
"""
import json
import math
import os
from pathlib import Path

import bpy
import numpy as np
from mathutils import Vector

ROOT = Path(__file__).resolve().parent
RESOURCES = ROOT.parent / "ios" / "Resources"
SCRATCH = ROOT / "renders" / "passes"
SCRATCH.mkdir(parents=True, exist_ok=True)
SAMPLES = int(os.environ.get("GENESIS_SAMPLES", "160"))
ONLY = {name for name in os.environ.get("GENESIS_ONLY", "").split(",") if name}

THETA = math.radians(24)
COS, SIN = math.cos(THETA), math.sin(THETA)

# ---------------------------------------------------------------- scene
bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)
scene = bpy.context.scene
scene.render.engine = "CYCLES"
scene.cycles.samples = SAMPLES
scene.cycles.use_denoising = True
scene.cycles.max_bounces = 10
scene.cycles.transmission_bounces = 10
scene.cycles.device = "CPU"
if os.environ.get("GENESIS_RENDER_DEVICE") == "METAL":
    try:
        preferences = bpy.context.preferences.addons["cycles"].preferences
        preferences.compute_device_type = "METAL"
        preferences.get_devices()
        for device in preferences.devices:
            device.use = device.type == "METAL"
        scene.cycles.device = "GPU"
    except Exception:
        scene.cycles.device = "CPU"
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGBA"
scene.render.image_settings.color_depth = "8"
scene.render.resolution_percentage = 100
world = scene.world or bpy.data.worlds.new("Studio")
scene.world = world
world.use_nodes = True
background = world.node_tree.nodes.get("Background")


def linear(v):
    return v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4


def rgb(h):
    return tuple(linear(((h >> s) & 255) / 255) for s in (16, 8, 0))


def material(name, color, rough=.4, metal=0.0, coat=0.0, translucent=0.0, specular=.5):
    """Principled surface, optionally mixed with diffuse transmission so a
    light behind the surface shows through it, as in a lit keycap."""
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    shader = nodes.get("Principled BSDF")
    shader.inputs["Base Color"].default_value = (*color, 1)
    shader.inputs["Roughness"].default_value = rough
    shader.inputs["Metallic"].default_value = metal
    shader.inputs["Coat Weight"].default_value = coat
    shader.inputs["Specular IOR Level"].default_value = specular
    if translucent:
        output = nodes.get("Material Output")
        through = nodes.new("ShaderNodeBsdfTranslucent")
        through.inputs["Color"].default_value = (1, 1, 1, 1)
        mix = nodes.new("ShaderNodeMixShader")
        mix.inputs["Fac"].default_value = translucent
        links.new(shader.outputs["BSDF"], mix.inputs[1])
        links.new(through.outputs["BSDF"], mix.inputs[2])
        links.new(mix.outputs["Shader"], output.inputs["Surface"])
    return mat


body_mat = material("Pearl body", rgb(0xE9ECEF), .46, 0, .12)
rim_mat = material("Polished rim", rgb(0xF6F7F9), .30, 0, .25)
plate_mat = material("Plate", rgb(0xC3C9D1), .52)
seam_mat = material("Seam", rgb(0x9099A2), .45, .2)
snow_mat = material("Snow keycap", rgb(0xFBFCFD), .40, 0, .22, translucent=.42)
housing_mat = material("Clear switch housing", rgb(0xC9CED4), .50, 0, 0, translucent=.62)
knob_snow_mat = material("Snow knob", rgb(0xFAFBFC), .36, 0, .25, translucent=.42)
graphite_mat = material("Graphite", rgb(0x101214), .55, 0, 0, specular=.22)
black_mat = material("Soft-touch black", rgb(0x050607), .62, 0, 0, specular=.12)
chrome_mat = material("Satin chrome", rgb(0xC9CFD4), .24, 1.0)
screw_mat = material("Screw", rgb(0x3A3F45), .35, .8)


def collection(name):
    c = bpy.data.collections.new(name)
    scene.collection.children.link(c)
    return c


shell_col = collection("Shell")
cap_col = collection("Keycap")
snow_knob_col = collection("Snow knob")
dark_knob_col = collection("Graphite knob")
puck_col = collection("Home puck")
stage_col = collection("Stage")
ALL = (shell_col, cap_col, snow_knob_col, dark_knob_col, puck_col)


def outline(width, depth, radius, steps=14):
    radius = min(radius, width / 2 - .001, depth / 2 - .001)
    points = []
    for cx, cy, start in ((width / 2 - radius, depth / 2 - radius, 0), (-width / 2 + radius, depth / 2 - radius, 90),
                          (-width / 2 + radius, -depth / 2 + radius, 180), (width / 2 - radius, -depth / 2 + radius, 270)):
        for n in range(steps + 1):
            a = math.radians(start + n * 90 / steps)
            points.append((cx + radius * math.cos(a), cy + radius * math.sin(a)))
    return points


def soften(obj, radius, segments=6):
    if radius > 0:
        modifier = obj.modifiers.new("Edge radius", "BEVEL")
        modifier.width = radius
        modifier.segments = segments
        modifier.limit_method = "ANGLE"
        modifier.angle_limit = math.radians(40)
    normals = obj.modifiers.new("Weighted normals", "WEIGHTED_NORMAL")
    normals.keep_sharp = True
    for polygon in obj.data.polygons:
        polygon.use_smooth = True
    return obj


def loft(name, lower, z0, upper, z1, mat, col, radius=.05, top=True, bottom=True, offset=(0, 0)):
    """A solid between two outlines with the same point count."""
    n = len(lower)
    vertices = [(x, y, z0) for x, y in lower] + [(x + offset[0], y + offset[1], z1) for x, y in upper]
    faces = [(i, (i + 1) % n, (i + 1) % n + n, i + n) for i in range(n)]
    if bottom:
        faces.append(tuple(reversed(range(n))))
    if top:
        faces.append(tuple(range(n, 2 * n)))
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    col.objects.link(obj)
    obj.data.materials.append(mat)
    return soften(obj, radius)


def slab(name, width, depth, z0, z1, radius, mat, col, edge=.05, at=(0, 0)):
    shape = [(x + at[0], y + at[1]) for x, y in outline(width, depth, radius)]
    return loft(name, shape, z0, shape, z1, mat, col, edge)


def frame(name, width, depth, radius, border, z0, z1, mat, col, edge=.04):
    outer = outline(width, depth, radius)
    inner = outline(width - border * 2, depth - border * 2, max(.05, radius - border))
    n = len(outer)
    vertices = [(x, y, z) for z in (z0, z1) for loop in (outer, inner) for x, y in loop]
    faces = []
    for i in range(n):
        j = (i + 1) % n
        faces += [(i, j, 2 * n + j, 2 * n + i), (n + j, n + i, 3 * n + i, 3 * n + j),
                  (j, i, n + i, n + j), (2 * n + i, 2 * n + j, 3 * n + j, 3 * n + i)]
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    col.objects.link(obj)
    obj.data.materials.append(mat)
    return soften(obj, edge, 5)


def cylinder(name, radius, z0, z1, mat, col, edge=.04, at=(0, 0), vertices=128, top_radius=None, top=True, bottom=True):
    lower = [(at[0] + radius * math.cos(math.tau * i / vertices), at[1] + radius * math.sin(math.tau * i / vertices)) for i in range(vertices)]
    r1 = radius if top_radius is None else top_radius
    upper = [(at[0] + r1 * math.cos(math.tau * i / vertices), at[1] + r1 * math.sin(math.tau * i / vertices)) for i in range(vertices)]
    return loft(name, lower, z0, upper, z1, mat, col, edge, top=top, bottom=bottom)


# ---------------------------------------------------------------- shell
SHELL = 10.52          # outer width and depth
BODY_DEPTH = 1.00      # how far the body drops below the plate
RIM_HEIGHT = 0.26
RIM_BORDER = 0.50
slab("Body", SHELL, SHELL, -BODY_DEPTH, 0.0, .86, body_mat, shell_col, .10)
slab("Foot seam", SHELL - .16, SHELL - .16, -BODY_DEPTH - .05, -BODY_DEPTH + .05, .80, seam_mat, shell_col, .02)
slab("Plate", SHELL - RIM_BORDER * 2 + .04, SHELL - RIM_BORDER * 2 + .04, -.03, 0.004, .44, plate_mat, shell_col, 0)
frame("Rim", SHELL, SHELL, .86, RIM_BORDER, -0.02, RIM_HEIGHT, rim_mat, shell_col, .07)
frame("Plate seam", SHELL - RIM_BORDER * 2 + .02, SHELL - RIM_BORDER * 2 + .02, .40, .035, 0.0, .012, seam_mat, shell_col, 0)
for sx in (-1, 1):
    for sy in (-1, 1):
        at = (sx * 4.36, sy * 4.36)
        cylinder("Screw seat", .20, 0.0, .016, seam_mat, shell_col, .004, at, 48)
        cylinder("Screw", .145, 0.0, .05, screw_mat, shell_col, .015, at, 48)
        cylinder("Hex", .07, .05, .052, black_mat, shell_col, 0, at, 6)

# ---------------------------------------------------------------- keycap
KEY = 1.74             # footprint
CAP_Z0, CAP_Z1 = 0.30, 0.92
TOP_W, TOP_D = 1.40, 1.36
TRAVEL = 0.25
slab("Switch housing", 1.22, 1.22, 0.0, CAP_Z0 + .04, .12, housing_mat, cap_col, .03)
cap = loft("Keycap", outline(KEY, KEY, .26), CAP_Z0, outline(TOP_W, TOP_D, .30), CAP_Z1, snow_mat, cap_col, .055, bottom=False)
cap_led = bpy.data.lights.new("Key LED", "POINT")
cap_led.energy = 9
cap_led.shadow_soft_size = .16
cap_led_obj = bpy.data.objects.new("Key LED", cap_led)
cap_led_obj.location = (0, 0, .20)
cap_col.objects.link(cap_led_obj)

# ---------------------------------------------------------------- knobs
KNOB_GRIP_R, KNOB_TOP_R = 0.84, 0.74
KNOB_Z1 = 1.02


def knob(col, body, top, ring):
    cylinder("Bearing", .92, 0.0, .07, ring, col, .02)
    # Open inside, like a moulded knob, so the LED lights the cap from within.
    cylinder("Grip", KNOB_GRIP_R - .03, .07, .66, body, col, .03, top=False, bottom=False)
    for i in range(64):
        a = math.tau * i / 64
        rib = slab("Knurl", .046, .05, .11, .62, .012, body, col, .01)
        rib.location = ((KNOB_GRIP_R - .01) * math.cos(a), (KNOB_GRIP_R - .01) * math.sin(a), 0)
        rib.rotation_euler.z = a
    cylinder("Waist", KNOB_GRIP_R - .03, .66, .74, body, col, .02, top_radius=KNOB_TOP_R, top=False, bottom=False)
    cylinder("Cap", KNOB_TOP_R, .74, KNOB_Z1, top, col, .07, bottom=False)


knob(snow_knob_col, knob_snow_mat, knob_snow_mat, chrome_mat)
knob(dark_knob_col, graphite_mat, black_mat, chrome_mat)
knob_led = bpy.data.lights.new("Knob LED", "POINT")
knob_led.energy = 22
knob_led.shadow_soft_size = .2
knob_led_obj = bpy.data.objects.new("Knob LED", knob_led)
knob_led_obj.location = (0, 0, .45)
snow_knob_col.objects.link(knob_led_obj)

# ---------------------------------------------------------------- home puck
PUCK_R, PUCK_Z1 = 0.66, 0.24
cylinder("Puck ring", PUCK_R + .12, 0.0, .09, chrome_mat, puck_col, .03)
cylinder("Puck", PUCK_R, .09, PUCK_Z1, black_mat, puck_col, .05)

# ---------------------------------------------------------------- stage
catcher = slab("Shadow catcher", 40, 40, -.01, 0.0, .1, plate_mat, stage_col, 0)
catcher.is_shadow_catcher = True
light_plate = slab("LED plate", 40, 40, -.01, 0.0, .1, plate_mat, stage_col, 0)


def sun(name, travel, strength, angle):
    data = bpy.data.lights.new(name, "SUN")
    data.energy = strength
    data.angle = math.radians(angle)
    obj = bpy.data.objects.new(name, data)
    obj.rotation_euler = Vector(travel).to_track_quat("-Z", "Y").to_euler()
    stage_col.objects.link(obj)
    return obj


# Key light from above and behind, so shadows fall toward the viewer and the
# front walls sit in soft shade: that contrast is what makes the keys stand up.
studio = [sun("Key", (.32, -.44, -.84), 4.0, 24), sun("Fill", (-.5, .55, -.67), .7, 70), sun("Front", (.05, .8, -.6), .16, 80)]

camera_data = bpy.data.cameras.new("Tilted orthographic")
camera_data.type = "ORTHO"
camera = bpy.data.objects.new("Tilted orthographic", camera_data)
stage_col.objects.link(camera)
scene.camera = camera
look = Vector((0, SIN, -COS))
camera.rotation_euler = look.to_track_quat("-Z", "Y").to_euler()


def aim(target, span, width, height):
    camera.location = Vector(target) - look * 40
    camera_data.ortho_scale = span * max(1, height / width) if height > width else span
    scene.render.resolution_x, scene.render.resolution_y = width, height


def project(point, target, span, width, height):
    """World point to pixel coordinates (origin top-left)."""
    scale = width / span
    x, y, z = (point[i] - target[i] for i in range(3))
    return (width / 2 + x * scale, height / 2 - (y * COS + z * SIN) * scale)


def show(*visible):
    for col in ALL:
        col.hide_render = col not in visible


def beauty(path):
    for light in studio:
        light.hide_render = False
    cap_led_obj.hide_render = knob_led_obj.hide_render = True
    catcher.hide_render, light_plate.hide_render = False, True
    background.inputs["Color"].default_value = (.86, .90, 1.0, 1)
    background.inputs["Strength"].default_value = .46
    scene.render.film_transparent = True
    scene.view_settings.view_transform = "AgX"
    scene.view_settings.look = "AgX - Medium High Contrast"
    scene.view_settings.exposure = 0.62
    scene.render.filepath = str(path)
    bpy.ops.render.render(write_still=True)
    clear_haze(path)


def clear_haze(path):
    """A dark control dims the whole shadow catcher slightly, which would
    show as a faint box around the sprite. Remove whatever opacity reaches
    the image border so the shadow fades to nothing."""
    image = bpy.data.images.load(str(path))
    width, height = image.size
    pixels = np.array(image.pixels[:], dtype=np.float32).reshape(height, width, 4)
    alpha = pixels[..., 3]
    border = np.concatenate([alpha[:4].ravel(), alpha[-4:].ravel(), alpha[:, :4].ravel(), alpha[:, -4:].ravel()])
    floor = float(np.percentile(border, 98)) + 1.5 / 255
    if floor > 2 / 255:
        pixels[..., 3] = np.clip((alpha - floor) / (1 - floor), 0, 1)
        image.pixels.foreach_set(pixels.ravel())
        image.save()
    bpy.data.images.remove(image)


def led_mask(path, led, floor=.035, gamma=.72):
    """Render only the LED, then store its brightness as the alpha of a white image."""
    for light in studio:
        light.hide_render = True
    cap_led_obj.hide_render = knob_led_obj.hide_render = True
    led.hide_render = False
    catcher.hide_render, light_plate.hide_render = True, False
    background.inputs["Strength"].default_value = 0
    scene.render.film_transparent = False
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "None"
    scene.view_settings.exposure = 0
    scene.render.image_settings.color_depth = "16"
    raw = SCRATCH / (Path(path).stem + "-led.png")
    scene.render.filepath = str(raw)
    bpy.ops.render.render(write_still=True)
    scene.render.image_settings.color_depth = "8"
    image = bpy.data.images.load(str(raw))
    width, height = image.size
    pixels = np.array(image.pixels[:], dtype=np.float32).reshape(height, width, 4)
    level = pixels[..., :3].max(axis=2)
    # Scale to the brightest part of the control, and drop the faint far
    # field so the light pools around the key instead of washing the plate.
    peak = max(float(np.percentile(level, 99.9)), 1e-6)
    alpha = np.clip((level / peak - floor) / (1 - floor), 0, 1) ** gamma
    out = np.ones((height, width, 4), dtype=np.float32)
    out[..., 3] = alpha
    mask = bpy.data.images.new(Path(path).stem, width, height, alpha=True)
    mask.alpha_mode = "STRAIGHT"
    mask.pixels.foreach_set(out.ravel())
    mask.filepath_raw = str(path)
    mask.file_format = "PNG"
    mask.save()
    bpy.data.images.remove(image)
    bpy.data.images.remove(mask)


def wanted(name):
    return not ONLY or name in ONLY


metrics = {"tiltDegrees": 24, "cos": COS, "sin": SIN}


def rect(points, target, span, width, height):
    xs, ys = zip(*(project(p, target, span, width, height) for p in points))
    return [round(min(xs), 2), round(min(ys), 2), round(max(xs) - min(xs), 2), round(max(ys) - min(ys), 2)]


# ---------------------------------------------------------------- renders
# Shell.
target, span, size = (0, 0, -.37), 11.5, 1536
h = SHELL / 2
metrics["shell"] = {
    "image": [size, size],
    "bounds": rect([(-h, h, RIM_HEIGHT), (h, h, RIM_HEIGHT), (-h, -h, -BODY_DEPTH - .05), (h, -h, -BODY_DEPTH - .05)], target, span, size, size),
    "plate": rect([(-h + RIM_BORDER, h - RIM_BORDER, 0), (h - RIM_BORDER, -h + RIM_BORDER, RIM_HEIGHT)], target, span, size, size),
    "pixelsPerUnit": size / span,
}
if wanted("shell"):
    # The app draws the body's own soft shadow, so it can follow any size.
    show(shell_col)
    catcher.location.z = -30
    aim(target, span, size, size)
    beauty(RESOURCES / "DeckShell.png")
    catcher.location.z = 0

# Keycap, up and down.
target, span, size = (0, 0, .42), 3.0, 640
k, t = KEY / 2, (TOP_W / 2, TOP_D / 2)
for state, drop in (("Up", 0.0), ("Down", TRAVEL)):
    z0, z1 = CAP_Z0 - drop, CAP_Z1 - drop
    metrics["cap" + state] = {
        "image": [size, size],
        "bounds": rect([(-k, k, z0), (k, -k, z0), (-t[0], t[1], z1), (t[0], t[1], z1)], target, span, size, size),
        "top": rect([(-t[0], t[1], z1), (t[0], -t[1], z1)], target, span, size, size),
        "pixelsPerUnit": size / span,
    }
    if wanted("cap"):
        show(cap_col)
        cap.location.z = -drop
        aim(target, span, size, size)
        beauty(RESOURCES / f"DeckCap{state}.png")
        led_mask(RESOURCES / f"DeckCap{state}Glow.png", cap_led_obj)
cap.location.z = 0

# Knobs.
target, span, size = (0, 0, .50), 3.0, 640
g = KNOB_GRIP_R + .08
knob_metrics = {
    "image": [size, size],
    "bounds": rect([(-g, 0, 0), (g, 0, 0), (0, -g, 0), (0, KNOB_TOP_R, KNOB_Z1)], target, span, size, size),
    "topCenter": [round(v, 2) for v in project((0, 0, KNOB_Z1), target, span, size, size)],
    "topRadius": round(KNOB_TOP_R * size / span, 2),
    "pixelsPerUnit": size / span,
}
metrics["knob"] = knob_metrics
if wanted("knob"):
    aim(target, span, size, size)
    show(snow_knob_col)
    beauty(RESOURCES / "DeckKnobSnow.png")
    led_mask(RESOURCES / "DeckKnobSnowGlow.png", knob_led_obj)
    show(dark_knob_col)
    beauty(RESOURCES / "DeckKnobGraphite.png")

# Home puck.
target, span, size = (0, 0, .12), 2.4, 512
p = PUCK_R + .12
metrics["puck"] = {
    "image": [size, size],
    "bounds": rect([(-p, 0, 0), (p, 0, 0), (0, -p, 0), (0, PUCK_R, PUCK_Z1)], target, span, size, size),
    "topCenter": [round(v, 2) for v in project((0, 0, PUCK_Z1), target, span, size, size)],
    "topRadius": round(PUCK_R * size / span, 2),
    "pixelsPerUnit": size / span,
}
if wanted("puck"):
    show(puck_col)
    aim(target, span, size, size)
    beauty(RESOURCES / "DeckPuck.png")

(ROOT / "deck-metrics.json").write_text(json.dumps(metrics, indent=2) + "\n")
# Save the scene with everything visible, ready to open and edit.
show(*ALL)
for light in studio:
    light.hide_render = False
catcher.hide_render, light_plate.hide_render = True, True
bpy.ops.wm.save_as_mainfile(filepath=str(ROOT / "GenesisDeck.blend"))
print("GENESIS_DECK_DONE", json.dumps(metrics))
