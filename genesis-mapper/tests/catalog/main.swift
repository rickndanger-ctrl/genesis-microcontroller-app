import Foundation
func check(_ value:Bool,_ message:String){if !value {fatalError(message)}}
check(ControllerAction.all.count==26,"Catalog count")
check(Set(ControllerAction.all.map(\.id)).count==26,"No duplicate dispatch IDs")
check(ControllerAction.all.allSatisfy{$0.id.utf8.count<12},"Firmware key capacity")
check(ControllerAction.menu(["model","model","bad","dictate","send"])==["send","dictate","model"],"Normalize saved choices without moving voice/send")
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
