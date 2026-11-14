"""Reproducible Genesis controller artwork, Blender 5.2+.

Run: blender -b --factory-startup --python design/build_controller.py
The native app renders all text, status, colored glows, and interaction above
these transparent components. No product screenshots or flat UI are baked in.
"""
import bpy
import bmesh
import math
import os
from pathlib import Path
from mathutils import Vector

ROOT = Path(__file__).resolve().parent
RESOURCES = ROOT.parent / "ios" / "Resources"
RESOURCES.mkdir(parents=True, exist_ok=True)

bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)
for col in list(bpy.data.collections):
    if col.name != "Collection":
        bpy.data.collections.remove(col)
scene = bpy.context.scene
scene.render.engine = "CYCLES"
scene.cycles.samples = 64
scene.cycles.use_denoising = True
scene.cycles.max_bounces = 8
scene.render.threads_mode = "FIXED"
scene.render.threads = 6
try:
    if os.environ.get("GENESIS_RENDER_DEVICE", "CPU") != "METAL":
        raise RuntimeError("CPU selected for reproducible background rendering")
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
scene.render.film_transparent = True
scene.view_settings.view_transform = "AgX"
scene.view_settings.look = "AgX - Medium High Contrast"
scene.render.resolution_percentage = 100
scene.world.color = (0.6, 0.65, 0.72)
world_nodes = scene.world.node_tree.nodes if scene.world.use_nodes else None
if world_nodes:
    world_nodes.get("Background").inputs["Color"].default_value = (0.64, 0.68, 0.75, 1)
    world_nodes.get("Background").inputs["Strength"].default_value = 0.32

def linear(v):
    return v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4

def rgb(h):
    return tuple(linear(((h >> s) & 255) / 255) for s in (16, 8, 0))

def material(name, color, rough=.35, metal=0, transmission=0, emission=0):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    shader = mat.node_tree.nodes.get("Principled BSDF")
    shader.inputs["Base Color"].default_value = (*color, 1)
    shader.inputs["Roughness"].default_value = rough
    shader.inputs["Metallic"].default_value = metal
    shader.inputs["Transmission Weight"].default_value = transmission
    shader.inputs["IOR"].default_value = 1.46
    shader.inputs["Coat Weight"].default_value = .28
    if emission:
        shader.inputs["Emission Color"].default_value = (*color, 1)
        shader.inputs["Emission Strength"].default_value = emission
    return mat

frost = material("Frosted pearl acrylic", rgb(0xE3E9EB), .26, .06, .30)
rim = material("Polished acrylic edge", rgb(0xF8FBFA), .18, .05, .15)
tray = material("Warm porcelain inset", rgb(0xDCE2E0), .39, .10)
lower = material("Smoked perimeter seam", rgb(0x9AA6A8), .42, .2)
white = material("Ceramic keycap", rgb(0xF8F9F5), .26, .08)
keybase = material("Keycap lower bevel", rgb(0xBEC8C8), .34, .18)
dark = material("Graphite soft touch", rgb(0x292E30), .38, .25)
black = material("Recessed graphite", rgb(0x10191D), .48, .12)
metal = material("Brushed silver", rgb(0xB8C4C7), .27, .86)
metal_bright = material("Satin silver top", rgb(0xE0E8E7), .28, .74)
marker = material("Dial index", rgb(0xF6F8EE), .30, .15)
colors = [0x3478F6, 0x9B5CF6, 0xF0529C, 0xFF9933, 0x30C778, 0x29C4DE]
lights = [material(f"Slot {i+1} light", rgb(c), .3, .03, .12, 1.2) for i, c in enumerate(colors)]

def collection(name):
    c = bpy.data.collections.new(name)
    scene.collection.children.link(c)
    return c

shell = collection("01 Shell — native overlay surface")
hero = collection("02 Hero controls — hide for empty deck")
key_asset = collection("03 Export — neutral keycap")
dial_asset = collection("04 Export — graphite dial")
silver_asset = collection("05 Export — silver dial")
studio = collection("06 Studio lighting and camera")

def move(obj, col):
    for c in list(obj.users_collection):
        c.objects.unlink(obj)
    col.objects.link(obj)
    return obj

def bevel(obj, radius, segments=8):
    modifier = obj.modifiers.new("Soft machined radius", "BEVEL")
    modifier.width = radius
    modifier.segments = segments
    normal = obj.modifiers.new("Weighted surface normals", "WEIGHTED_NORMAL")
    normal.keep_sharp = True
    return obj

def box(name, size, loc, mat, col, radius=.15):
    width,height,depth = size
    loop = outline(width,height,min(radius,width/2-.001,height/2-.001))
    n=len(loop)
    vertices=[(x,y,z) for z in (-depth/2,depth/2) for x,y in loop]
    faces=[tuple(reversed(range(n))),tuple(range(n,2*n))]
    faces.extend((i,(i+1)%n,(i+1)%n+n,i+n) for i in range(n))
    mesh=bpy.data.meshes.new(name)
    mesh.from_pydata(vertices,[],faces)
    mesh.update()
    obj=bpy.data.objects.new(name,mesh)
    col.objects.link(obj)
    obj.location=loc
    obj.data.materials.append(mat)
    bevel(obj,min(.055,depth*.22,radius*.2),5)
    return obj

def cylinder(name, radius, depth, loc, mat, col, edge=.04, vertices=96):
    bpy.ops.mesh.primitive_cylinder_add(vertices=vertices, radius=radius, depth=depth, location=loc)
    obj = bpy.context.object
    obj.name = name
    obj.data.materials.append(mat)
    bevel(obj, edge, 5)
    for p in obj.data.polygons:
        p.use_smooth = True
    return move(obj, col)

def outline(width, height, radius, steps=16):
    points = []
    for cx, cy, start in [(width/2-radius,height/2-radius,0),(-width/2+radius,height/2-radius,90),(-width/2+radius,-height/2+radius,180),(width/2-radius,-height/2+radius,270)]:
        for n in range(steps+1):
            a = math.radians(start + n * 90 / steps)
            points.append((cx+radius*math.cos(a),cy+radius*math.sin(a)))
    return points

def ring(name, width, height, rad, border, z, depth, mat, col, center=(0,0)):
    outer = outline(width,height,rad)
    inner = outline(width-border*2,height-border*2,max(.03,rad-border))
    n = len(outer)
    vertices = [(x+center[0],y+center[1],zz) for zz in (z-depth/2,z+depth/2) for loop in (outer,inner) for x,y in loop]
    faces = []
    for i in range(n):
        j=(i+1)%n
        faces.extend([(i,j,n+j,n+i),(2*n+i,3*n+i,3*n+j,2*n+j),(i,2*n+i,2*n+j,j),(n+i,n+j,3*n+j,3*n+i)])
    mesh=bpy.data.meshes.new(name)
    mesh.from_pydata(vertices,[],faces)
    bm=bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.recalc_face_normals(bm,faces=list(bm.faces))
    bm.to_mesh(mesh)
    bm.free()
    mesh.update()
    obj=bpy.data.objects.new(name,mesh)
    col.objects.link(obj)
    obj.data.materials.append(mat)
    bevel(obj,min(.045,depth/3,border/3),4)
    return obj

box("Perimeter shadow seam",(10.4,10.4,.29),(0,0,-.02),lower,shell,.73)
box("Frosted acrylic base",(10.52,10.52,.46),(0,0,.14),frost,shell,.79)
box("Recessed interior tray",(9.4,9.4,.15),(0,0,.385),tray,shell,.58)
ring("Luminous machined rim",10.48,10.48,.84,.33,.47,.17,rim,shell)
ring("Inset acrylic seam",9.49,9.49,.64,.045,.48,.035,lower,shell)
for x in (-4.21,4.21):
    for y in (-4.21,4.21):
        cylinder("Screw recess",.24,.035,(x,y,.49),lower,shell,.01)
        cylinder("Screw socket",.172,.065,(x,y,.51),dark,shell,.025)
        cylinder("Hex inset",.083,.012,(x,y,.546),black,shell,.005,6)
        cylinder("Hex bottom highlight",.043,.005,(x,y,.554),dark,shell,.002,6)

def key(name,col,x=0,y=0,z=.65,width=1.74,height=1.74,light=None):
    box(name+" shadow foot",(width+.08,height+.08,.17),(x,y,z-.10),keybase,col,.22)
    box(name+" porcelain",(width,height,.36),(x,y,z+.09),white,col,.24)
    if light:
        ring(name+" color surround",width+.17,height+.17,.29,.06,z-.03,.07,light,col,(x,y))
        cylinder(name+" identity LED",.205,.025,(x,y,z+.285),light,col,.02)

def dial(name,col,x=0,y=0,z=.70,silver=False):
    bodymat=metal if silver else dark
    topmat=metal_bright if silver else dark
    cylinder(name+" bearing",.91,.09,(x,y,z-.17),black,col,.035)
    cylinder(name+" turned body",.855,.44,(x,y,z+.035),bodymat,col,.06)
    for i in range(48):
        angle=math.tau*i/48
        rib=box(name+" knurl",(.044,.06,.29),(x+.847*math.cos(angle),y+.847*math.sin(angle),z+.035),bodymat,col,.012)
        rib.rotation_euler.z=angle
    cylinder(name+" cap",.813,.09,(x,y,z+.285),topmat,col,.035)
    index=box(name+" index",(.055,.28,.014),(x,y+.56,z+.34),dark if silver else marker,col,.019)
    if silver:
        blade=box(name+" raised grip",(1.55,.14,.17),(x,y,z+.37),metal,col,.06)
        blade.rotation_euler.z=math.radians(43)

key("Neutral key",key_asset,z=.15)
dial("Graphite dial",dial_asset,z=.2)
dial("Silver dial",silver_asset,z=.2,silver=True)

positions=[(-1.03,3.04),(1.03,3.04),(-3.08,.99),(-1.03,.99),(1.03,.99),(3.08,.99)]
for i,(x,y) in enumerate(positions):
    key(f"Slot {i+1}",hero,x,y,light=lights[i])
dial("Left silver dial",hero,-3.08,3.04,silver=True)
dial("Right graphite dial",hero,3.08,3.04)
for i,x in enumerate((-3.08,-1.03,1.03,3.08)):
    key(f"Action {i+1}",hero,x,-1.08)
key("Wide talk key",hero,0,-3.14,width=3.80)
key("Artifact key",hero,3.08,-3.14)
cylinder("Home control recess",.50,.045,(-3.08,-3.14,.51),metal,hero,.02)
cylinder("Home control",.39,.055,(-3.08,-3.14,.55),black,hero,.035)
for n in range(3):
    cylinder(f"Status dot {n}",.055,.022,(-3.88,-2.91-n*.17,.51),lights[n],hero,.01)

def area(name,position,energy,size,color):
    bpy.ops.object.light_add(type="AREA",location=position)
    obj=bpy.context.object
    obj.name=name
    obj.data.energy=energy
    obj.data.shape="DISK"
    obj.data.size=size
    obj.data.color=color
    obj.rotation_euler=(Vector((0,0,.4))-obj.location).to_track_quat("-Z","Y").to_euler()
    move(obj,studio)
area("Large softbox upper left",(-7,6,14),1700,9,(1,.97,.90))
area("Cool fill right",(9,0,10),1100,8,(.91,.95,1))
area("Rim strip",(0,7,8),900,7,(1,1,1))
bpy.ops.object.camera_add(location=(0,-3.6,35))
camera=bpy.context.object
camera.name="Orthographic product camera"
camera.rotation_euler=(Vector((0,0,.25))-camera.location).to_track_quat("-Z","Y").to_euler()
camera.data.type="ORTHO"
scene.camera=camera
move(camera,studio)

def render(name,visible,scale,res,output):
    for c in (shell,hero,key_asset,dial_asset,silver_asset):
        c.hide_render=c not in visible
        c.hide_viewport=c not in visible
    camera.data.ortho_scale=scale
    scene.render.resolution_x=res
    scene.render.resolution_y=res
    scene.render.filepath=str(output)
    bpy.ops.render.render(write_still=True)
    print("GENESIS_ASSET",name,output,flush=True)

render("Shell",(shell,),11.5,1536,RESOURCES/"ControllerShell.png")
render("Key",(key_asset,),2.25,512,RESOURCES/"ControllerKey.png")
render("Dial",(dial_asset,),2.25,512,RESOURCES/"ControllerDial.png")
render("Silver dial",(silver_asset,),2.25,512,RESOURCES/"ControllerDialSilver.png")
render("Hero",(shell,hero),11.5,1536,ROOT/"ControllerHero.png")
scene["readme"]="Genesis Agent Micro Controller. All geometry/materials editable. Scene script regenerates individual transparent SwiftUI assets. Native app supplies text and interaction."
scene["slot_palette"]="3478F6 9B5CF6 F0529C FF9933 30C778 29C4DE"
bpy.ops.wm.save_as_mainfile(filepath=str(ROOT/"GenesisController.blend"))
