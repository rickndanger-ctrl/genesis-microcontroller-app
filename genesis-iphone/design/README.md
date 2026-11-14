# Blender controller artwork

`build_controller.py` (Blender 5.2+) creates the editable `GenesisController.blend` scene and the rendered assets. It uses Cycles on six CPU threads,
transparent PNG output, and a softly lit near-front orthographic product camera.

```sh
blender -b --factory-startup --python design/build_controller.py
```

Set `GENESIS_RENDER_DEVICE=METAL` to opt into Metal rendering. The default
avoids the long first-use Metal shader compilation on macOS.

Run `blender -b --factory-startup --python design/build_icon.py` after the main
builder to composite the hero onto a light opaque canvas for the iOS AppIcon.
The resulting `Assets.xcassets/AppIcon.appiconset/icon1024.png` is RGB (no alpha),
1024 × 1024, and has light corners before iOS applies its icon mask.

Exports:

| File | Pixels | Use |
| --- | --- | --- |
| `../ios/Resources/ControllerShell.png` | 1536 × 1536 | Empty frosted deck, inset tray and corner screws |
| `../ios/Resources/ControllerKey.png` | 512 × 512 | Neutral raised keycap; native label and tint overlays |
| `../ios/Resources/ControllerDial.png` | 512 × 512 | Graphite dial with index mark |
| `../ios/Resources/ControllerDialSilver.png` | 512 × 512 | Satin silver dial with raised grip |
| `ControllerHero.png` | 1536 × 1536 | Assembled reference render, without text |

The six slot identities are blue `#3478F6`, purple `#9B5CF6`, pink `#F0529C`,
orange `#FF9933`, green `#30C778`, and cyan `#29C4DE`. The native app, not the
shell image, should draw status/selection glows and the current chat names.

## Layout

The shell geometry is 10.52 units square in an 11.5-unit camera frame. Its
useful inset is approximately 81% of the image width, centered. Keep touch
controls within that inset. The assembled preview follows the reference:
silver dial / slots 1–2 / graphite dial; slots 3–6; four action keys; large
Talk key between Home and Artifacts. Individual asset canvases include a
transparent margin of approximately 10% per side.

Use native minimum 44-point hit targets, VoiceOver labels, scalable text,
reduced-motion support and press animations. No words or app logos are baked
into the render. The scene collections separate shell, hero controls,
individual assets and studio lighting; hide the hero controls for an empty
deck render.
