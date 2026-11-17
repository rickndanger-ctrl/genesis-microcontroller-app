# Controller artwork and sounds

`build_deck.py` (Blender 5.2+) is the controller's model and the source of everything the app draws on the deck.
`GenesisDeck.blend` is the scene it saves, ready to open and edit.

```sh
blender -b --factory-startup --python design/build_deck.py
```

The camera is orthographic and tilted 24 degrees toward the viewer. Orthographic means one keycap render is correct at
every position on the grid, so the app lays the keys out itself and stretches the middle of each render to fit taller
or wider keys while leaving the corners alone. Each control gets a beauty pass on a transparent film with its own
shadow. Lit controls also get an LED pass, rendered with the studio dark and a white LED under the control, and stored
as a white image whose alpha is the light's intensity. The app tints that mask with a slot color and fades it with the
glow level.

| File in `../ios/Resources` | Pixels | Use |
| --- | --- | --- |
| `DeckShell.png` | 1536 × 1536 | Body, rim, plate and screws |
| `DeckCapUp.png`, `DeckCapDown.png` | 640 × 640 | Keycap at rest and pressed |
| `DeckCapUpGlow.png`, `DeckCapDownGlow.png` | 640 × 640 | LED masks for those two states |
| `DeckKnobSnow.png`, `DeckKnobSnowGlow.png` | 640 × 640 | Chat knob and its LED mask |
| `DeckKnobGraphite.png` | 640 × 640 | Artifact knob |
| `DeckPuck.png` | 512 × 512 | Home button |

`deck-metrics.json` records where each control sits inside its image. Those numbers are copied into `DeckArt` in
`../ios/Sources/DeckSurfaces.swift`; update them there if the geometry or camera changes. Set `GENESIS_SAMPLES` for
quality (default 160), `GENESIS_ONLY=cap,knob,puck,shell` to render part of the set, and `GENESIS_RENDER_DEVICE=METAL`
for the GPU. Raw LED passes are written to `renders/passes/` and are not tracked.

The pointer, slot lights, legends and activity matrix are drawn by the app on top of the renders, foreshortened to
match the tilt. The older scene below remains the source of the app icon; its renders are kept in `renders/` for
reference and are not bundled.

## Click sounds

`build_sounds.py` (Python 3 with numpy and scipy) synthesizes the Crunch, Thock, Clack and Arcade packs into
`../ios/Resources/Click*.wav`. Each pack is a key click and a shorter dial detent, normalized just below full scale.
The seed is fixed, so a rebuild reproduces the same files. The Soft pack is the original `KeyClick.wav` / `DialTick.wav`.

```sh
python3 design/build_sounds.py
```

To add a pack, write its two builders, add them to the list at the bottom of the script, and add a matching entry to
`ControllerSound.packs`.

## Blender artwork

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
| `renders/ControllerShell.png` | 1536 × 1536 | Empty frosted deck, inset tray and corner screws |
| `renders/ControllerKey.png` | 512 × 512 | Neutral raised keycap; native label and tint overlays |
| `renders/ControllerDial.png` | 512 × 512 | Graphite dial with index mark |
| `renders/ControllerDialSilver.png` | 512 × 512 | Satin silver dial with raised grip |
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
