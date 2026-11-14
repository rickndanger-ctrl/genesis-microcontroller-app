"""Composite the rendered Blender hero onto an opaque light app-icon canvas."""
import bpy
from pathlib import Path

ROOT = Path(__file__).resolve().parent
OUTPUT = ROOT.parent / "ios/Resources/Assets.xcassets/AppIcon.appiconset/icon1024.png"
OUTPUT.parent.mkdir(parents=True, exist_ok=True)
bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)
scene = bpy.context.scene
scene.render.engine = "CYCLES"
scene.cycles.device = "CPU"
scene.cycles.samples = 1
scene.render.resolution_x = 1024
scene.render.resolution_y = 1024
scene.render.resolution_percentage = 100
scene.render.film_transparent = True
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGB"
scene.render.image_settings.color_depth = "8"
scene.view_settings.view_transform = "Standard"
scene.view_settings.look = "None"
scene.view_settings.exposure = 0
scene.view_settings.gamma = 1
bpy.ops.object.camera_add(location=(0, 0, 10))
scene.camera = bpy.context.object

tree = bpy.data.node_groups.new("Opaque Genesis app icon", "CompositorNodeTree")
tree.interface.new_socket(name="Image", in_out="OUTPUT", socket_type="NodeSocketColor")
scene.compositing_node_group = tree
scene.render.use_compositing = True
image = tree.nodes.new("CompositorNodeImage")
image.image = bpy.data.images.load(str(ROOT / "ControllerHero.png"))
image.image.scale(1024, 1024)
over = tree.nodes.new("CompositorNodeAlphaOver")
over.inputs["Factor"].default_value = 1
# Linear equivalent of a very light neutral gray; fully opaque background.
over.inputs["Background"].default_value = (.90, .92, .93, 1)
output = tree.nodes.new("NodeGroupOutput")
tree.links.new(image.outputs["Image"], over.inputs["Foreground"])
tree.links.new(over.outputs["Image"], output.inputs["Image"])
scene.render.filepath = str(OUTPUT)
bpy.ops.render.render(write_still=True)
print("GENESIS_ICON", OUTPUT, flush=True)
