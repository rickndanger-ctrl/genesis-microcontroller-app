import Foundation
func check(_ value:Bool,_ message:String){if !value {fatalError(message)}}
check(ControllerAction.all.count==26,"Catalog count")
check(Set(ControllerAction.all.map(\.id)).count==26,"No duplicate dispatch IDs")
check(ControllerAction.all.allSatisfy{$0.id.utf8.count<12},"Firmware key capacity")
check(ControllerAction.menu(["model","model","bad","dictate","send"])==["send","dictate","model"],"Normalize saved choices without moving voice/send")
// The permission chooser is found beside "Model:", whatever mode names it.
let row:[(role:String,text:String)]=[("AXPopUpButton","Model: Fable 5.2 High"),("AXPopUpButton","Plan mode"),("AXPopUpButton","Usage: Weekly 65%"),("AXGroup","")]
check(ControllerAction.permissionChooser(among:row)==1,"A mode the catalog has never heard of is still found")
check(ControllerAction.permissionChooser(among:[row[1],row[0],row[2]])==0,"Order within the row does not matter")
check(ControllerAction.permissionChooser(among:[row[0],row[2]])==nil,"No chooser beside Model means no click")
check(ControllerAction.permissionChooser(among:row+[("AXPopUpButton","Add")])==nil,"Two candidates are ambiguous, so no click")
check(ControllerAction.permissionChooser(among:[row[1],row[2]])==nil,"A row without Model is not the composer row")
check(ControllerAction.permissionChooser(among:[row[0],row[0],row[1]])==nil,"Two Model choosers are not a composer row")
check(ControllerAction.permissionChooser(among:[row[0],("AXButton","Plan mode"),row[2]])==nil,"Only a chooser counts, not a plain button")
let config="""
[desktop.codex-micro-layout]
separateMicrophoneKeys = false
voiceButtonMode = "push-to-talk"
encoderMode = "composer-navigation"
[desktop.codex-micro-layout.slots.ACT06]
keycapId = "APPR"
[desktop.codex-micro-layout.slots.ACT07]
keycapId = "YOLO"
[desktop.codex-micro-layout.slots.ACT10_ACT11]
keycapId = "MIC"
[desktop.codex-micro-layout.slots.ACT12]
keycapId = "CODEX"
[desktop.codex-micro-layout.analogStick.up]
type = "command"
commandId = "composer.togglePlanMode"
"""
let controls=CodexControls.read(config)
check(controls.count==12,"Native surface count")
check(controls[0].title=="Approve" && controls[1].title=="Type :yolo:","Respect remapped keys")
check(controls[4].isSend && controls[5].isTalk,"Semantic auto-return follows mappings")
check(controls[4].title=="Send prompt" && controls[5].title=="Hold to talk","Correct microphone/send positions")
check(!controls[6].enabled,"Combined mic suppresses ACT11")
check(controls[7].enabled && !controls[8].enabled,"Only mapped directions enabled")
check(controls[11].detail=="composer-navigation","Native dial setting")
let split=CodexControls.read(config.replacingOccurrences(of:"separateMicrophoneKeys = false",with:"separateMicrophoneKeys = true")+"\n[desktop.codex-micro-layout.slots.ACT11]\nkeycapId = 'TERM'\n")
check(split[6].enabled && split[6].title=="Terminal","Second mic switch can be assigned")
check(CodexControls.screenLabel("Model · effort…")=="Model - effort...","Display-safe labels")
check(CodexControls.screenLabel(String(repeating:"x",count:50)).count==25,"Bounded labels")
print("Action catalog, native remapping, split mic, directions and label tests passed")
