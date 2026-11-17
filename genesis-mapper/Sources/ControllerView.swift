import SwiftUI
import AppKit

struct MainView: View {
 @ObservedObject var model: Model
 @State private var selectedKey=0
 @State private var section=0
 @State private var actionSearch=""
 @State private var nativeSearch=""
 private let accent=Color(red:0.61,green:0.36,blue:0.96)
 private let keyColors:[Color]=[0x3478f6,0x9b5cf6,0xf0529c,0xff9933,0x30c778,0x29c4de].map { rgb in Color(red:Double((rgb>>16)&255)/255,green:Double((rgb>>8)&255)/255,blue:Double(rgb&255)/255) }
 private let panel=Color(red:0.065,green:0.085,blue:0.12)
 func stateColor(_ state:String)->Color {
  switch state {case "Working","Running":return .blue;case "Awaiting input","Needs input":return .orange;case "Something went wrong":return .red;case "Unread":return .green;case "Idle":return .purple;default:return .gray}
 }
 var body: some View {
  HStack(spacing:0) {
   VStack(alignment:.leading,spacing:10) {
    Image(nsImage:NSImage(contentsOf:Bundle.main.url(forResource:"Genesis",withExtension:"png")!) ?? NSImage()).resizable().scaledToFit().frame(width:76,height:76).clipShape(RoundedRectangle(cornerRadius:18)).padding(.bottom,8)
    Text("AGENT MICRO").font(.system(size:17,weight:.bold,design:.rounded)).lineSpacing(3)
    Text("CONTROLLER").font(.system(size:9,weight:.semibold)).tracking(2).foregroundStyle(.secondary).padding(.bottom,24)
    nav("Agent keys",icon:"square.grid.3x2",index:0)
    nav("Actions",icon:"waveform",index:1)
    nav("Codex controls",icon:"dial.low",index:2)
    nav("Device",icon:"slider.horizontal.3",index:3)
    Spacer()
    HStack(spacing:7) {Circle().fill(model.mode=="Claude" || model.mode=="Codex" ? Color.green:Color.gray).frame(width:7,height:7);Text(model.mode).font(.caption)}
    Text("CLAUDE + CODEX").font(.caption2).foregroundStyle(.secondary)
   }.padding(24).frame(width:190,alignment:.leading).background(panel)
   VStack(alignment:.leading,spacing:20) {
    HStack(alignment:.top) {
     VStack(alignment:.leading,spacing:5) {Text(section==0 ? "Agent keys":section==1 ? "Claude actions":section==2 ? "Codex controls":"Device settings").font(.system(size:26,weight:.semibold));Text(section==0 ? "Six keys. Your agents. One dial.":section==1 ? "Make the next press yours.":"Your controller, ready when you are.").foregroundStyle(.secondary)}
     Spacer()
     Text(model.mode=="Claude" ? "CLAUDE MODE":model.mode=="Codex" ? "CODEX MODE":"OFFLINE").font(.system(size:10,weight:.semibold)).padding(.horizontal,12).padding(.vertical,7).background(accent.opacity(0.12)).clipShape(Capsule())
    }
    if !model.trusted {
     HStack {Image(systemName:"hand.raised.fill");Text("Allow Agent Micro Controller to use Claude’s controls.");Spacer();Button("Enable access"){NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)}}.font(.callout).padding(12).background(Color.orange.opacity(0.12)).cornerRadius(10)
    }
    if section==0 {agentPage}
    else if section==1 {actionsPage}
    else if section==2 {codexPage}
    else {devicePage}
    Spacer(minLength:0)
    HStack(alignment:.top,spacing:9) {Image(systemName:"info.circle").foregroundStyle(accent);Text(model.status).font(.callout).textSelection(.enabled);Spacer()}.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(panel).cornerRadius(12)
   }.padding(28).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
  }.frame(minWidth:980,minHeight:700).background(LinearGradient(colors:[Color(red:0.035,green:0.045,blue:0.07),Color(red:0.065,green:0.08,blue:0.12)],startPoint:.topLeading,endPoint:.bottomTrailing)).tint(accent).preferredColorScheme(.dark)
 }
 func nav(_ title:String,icon:String,index:Int)->some View {
  Button {section=index} label:{Label(title,systemImage:icon).font(.system(size:13,weight:section==index ? .semibold:.regular)).frame(maxWidth:.infinity,alignment:.leading).padding(11).background(section==index ? accent.opacity(0.14):Color.clear).cornerRadius(9)}.buttonStyle(.plain)
 }
 var agentPage: some View {
  HStack(alignment:.top,spacing:24) {
   VStack(spacing:18) {
    HStack {Circle().fill(.green.opacity(model.mode=="Claude" ? 1:0.2)).frame(width:6,height:6);Text("AGENT MICRO  /  CONTROL DECK").font(.system(size:9,weight:.bold,design:.monospaced)).tracking(1);Spacer();Image(systemName:"cable.connector").foregroundStyle(.secondary)}
    LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:10),count:3),spacing:10) {
     ForEach(0..<6,id:\.self) {i in
      Button {selectedKey=i} label:{VStack(spacing:9) {HStack {Circle().fill(keyColors[i]).frame(width:7,height:7);Spacer();Text("C\(i+1)").font(.system(size:11,weight:.bold,design:.monospaced))};Text(model.slotLabel(i)).font(.system(size:11,weight:.medium)).lineLimit(2).frame(maxWidth:.infinity,minHeight:30,alignment:.leading)}.padding(11).frame(height:94).background(keyColors[i].opacity(selectedKey==i ? 0.25:0.09)).cornerRadius(11).overlay(RoundedRectangle(cornerRadius:11).stroke(keyColors[i].opacity(selectedKey==i ? 1:0.35),lineWidth:selectedKey==i ? 2:1))}.buttonStyle(.plain).accessibilityLabel("Configure C\(i+1)")
     }
    }
    HStack {
     VStack(alignment:.leading,spacing:6) {Text("TURN TO CHOOSE").font(.system(size:9,weight:.semibold)).tracking(1);Text("Click to act · double-click back").font(.caption).foregroundStyle(.secondary)}
     Spacer()
     ZStack {Circle().fill(Color(red:0.035,green:0.045,blue:0.07)).frame(width:72,height:72).shadow(color:.black.opacity(0.12),radius:3,y:2);Circle().stroke(accent.opacity(0.4),lineWidth:2).frame(width:58,height:58);Capsule().fill(accent).frame(width:3,height:10).offset(y:-22);Image(systemName:"arrow.trianglehead.2.clockwise.rotate.90").foregroundStyle(.secondary)}
    }
    HStack {Label("Hold to talk",systemImage:"mic");Spacer();Label("Send",systemImage:"paperplane")}.font(.caption).foregroundStyle(.secondary)
   }.padding(20).frame(width:355).background(panel).cornerRadius(23).overlay(RoundedRectangle(cornerRadius:23).stroke(.primary.opacity(0.08)))
   VStack(alignment:.leading,spacing:18) {
    HStack {Text("C\(selectedKey+1)").font(.system(size:42,weight:.bold,design:.rounded));Spacer();Text("KEY CONFIGURATION").font(.system(size:9,weight:.bold,design:.monospaced)).tracking(1.4).foregroundStyle(accent)}
    Text("Make it yours").font(.headline)
    Picker("Assignment type",selection:$model.slotActions[selectedKey]) {
     Text("Chat").tag("chat")
     ForEach(ControllerAction.groups,id:\.self) {group in
      Section(group) {ForEach(ControllerAction.all.filter{$0.group==group}) {action in Text(action.title).tag(action.id)}}
     }
    }
    if model.slotActions[selectedKey]=="chat" {
    Picker("Claude session",selection:$model.slots[selectedKey]) {
     Text("Unassigned").tag("")
     if !model.slots[selectedKey].isEmpty && !model.knownTitles.contains(model.slots[selectedKey]) {Text(model.slots[selectedKey]+" (not visible)").tag(model.slots[selectedKey])}
     ForEach(model.knownTitles,id:\.self){Text($0).tag($0)}
    }.labelsHidden().frame(maxWidth:.infinity)
    }
    if let action=ControllerAction.find(model.slotActions[selectedKey]) {Text(action.detail).font(.caption).foregroundStyle(.secondary)}
    Label(model.slotState(selectedKey),systemImage:"circle.fill").font(.caption).foregroundStyle(keyColors[selectedKey])
    Button(model.slotActions[selectedKey]=="chat" ? "Open C\(selectedKey+1)" : "Run C\(selectedKey+1)"){model.selectSlot(selectedKey)}.buttonStyle(.borderedProminent).disabled(model.mode != "Claude" || (model.slotActions[selectedKey]=="chat" && model.slots[selectedKey].isEmpty) || model.selecting)
    Button("Refresh sessions",systemImage:"arrow.clockwise"){model.discoverSessions()}
    Divider()
    Text("Refresh sessions discovers Claude chats. Saved choices remain available when the sidebar is closed.").font(.caption).foregroundStyle(.secondary)
    Text("Middle button: switch Claude / Codex. Double-click the dial: return to chats.").font(.caption).foregroundStyle(.secondary)
   }.frame(maxWidth:.infinity,alignment:.leading)
  }
 }
 var actionsPage: some View {
  ScrollView {
   VStack(alignment:.leading,spacing:18) {
    GroupBox("Menu navigation") {
     VStack(alignment:.leading,spacing:10) {
      Toggle("Use the knob inside menus and file pickers",isOn:$model.menuNavigationEnabled)
      Text("Turn: move · Tap: select · Double-tap: back one level · Triple-tap: chat slots").font(.callout)
      Text(model.navigationMessage).font(.caption).foregroundStyle(.secondary)
      if !model.supportsNavigation {Text("Requires firmware v0.2.23 or later.").font(.caption).foregroundStyle(.orange)}
      Text("Only supported popups in the selected agent app are controlled. Normal talk/send and double-click back stay the same outside a popup.").font(.caption).foregroundStyle(.secondary)
     }.padding(10)
    }
    GroupBox {VStack(alignment:.leading,spacing:12) {
     actionPicker("Microphone key",icon:"mic.fill",selection:$model.microphoneAction)
     Divider()
     actionPicker("Send key",icon:"paperplane.fill",selection:$model.sendAction)
     Toggle("After opening a chat, jump to Hold to talk",isOn:$model.talkAfterSelect)
    }.padding(12)}
    Text("Keep Hold to record off in Claude. Send stays one click left of Hold to talk. Double-click returns to chats.").font(.callout).foregroundStyle(.secondary)
    TextField("Search actions",text:$actionSearch).textFieldStyle(.roundedBorder)
    HStack {Text("ON THE CONTROLLER").font(.caption.bold());Spacer();Button("Show all"){model.menuActions=ControllerAction.menu(nil)};Text("\(model.menuActions.count) actions").font(.caption).foregroundStyle(.secondary)}
    if !model.supportsCatalog {Text("Assign any action to C1–C6 now. The expanded knob menu needs firmware v0.2.22 or later.").font(.caption).foregroundStyle(.orange)}
    ForEach(ControllerAction.groups,id:\.self) {group in
     let actions=ControllerAction.all.filter{$0.group==group && (actionSearch.isEmpty || ($0.title+" "+$0.detail).localizedCaseInsensitiveContains(actionSearch))}
     if !actions.isEmpty {
      Text(group).font(.headline)
      ForEach(actions) {action in
       HStack(alignment:.top) {
        Toggle(isOn:Binding(get:{model.menuActions.contains(action.id)},set:{model.toggleMenu(action.id,$0)})) {VStack(alignment:.leading,spacing:3) {Text(action.title);Text(action.detail).font(.caption).foregroundStyle(.secondary)}}
         .disabled(action.id=="send" || action.id=="dictate")
        Button("Run"){model.runAction(action.id)}.disabled(model.selecting || model.actionBusy)
       }.padding(10).background(panel).cornerRadius(9)
      }
     }
    }
   }
  }
 }
 var codexPage: some View {
  ScrollView {
   VStack(alignment:.leading,spacing:16) {
    Text("Codex owns its mappings. Choose chats, shortcuts, keycaps or skills in Settings → Codex Micro. Agent Micro Controller mirrors those assignments; changing a keycap can also change its command.").font(.callout).foregroundStyle(.secondary)
    HStack {Text("CURRENT NATIVE CONTROLS").font(.caption.bold());Spacer();Button("Refresh mappings"){model.nativeControls=CodexControls.current();model.syncCatalog()}}
    ForEach(model.nativeControls) {control in
     HStack {VStack(alignment:.leading,spacing:3) {Text(control.title).font(.headline);Text(control.detail).font(.caption).foregroundStyle(.secondary)};Spacer();Text(control.enabled ? "Available":"Unassigned").font(.caption).foregroundStyle(control.enabled ? Color.green:Color.secondary)}.padding(12).background(panel).cornerRadius(9)
    }
    Text("Native dial: turn and press using Codex’s Composer navigation, Reasoning, Conversation scroll, or Custom setting. Double-click returns to chats. The four directional choices run your analog-stick assignments without needing a separate joystick.").font(.caption).foregroundStyle(.secondary)
    Divider()
    Text("Native shortcut reference").font(.headline)
    Text("The installed app registers \(NativeCommandNames.titles.count) command choices. Availability depends on the open chat, platform and enabled features. Assign these in Codex; this list does not run commands.").font(.caption).foregroundStyle(.secondary)
    TextField("Search native commands",text:$nativeSearch).textFieldStyle(.roundedBorder)
    ForEach(NativeCommandNames.titles.keys.sorted().filter{nativeSearch.isEmpty || ($0+" "+(NativeCommandNames.titles[$0] ?? "")).localizedCaseInsensitiveContains(nativeSearch)},id:\.self) {id in
     HStack {Text(NativeCommandNames.titles[id] ?? id);Spacer();Text(id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)}.padding(.vertical,3)
    }
   }
  }
 }
 func actionPicker(_ title:String,icon:String,selection:Binding<String>)->some View {
  HStack {Label(title,systemImage:icon).font(.headline);Spacer();Picker(title,selection:selection){ForEach(ControllerAction.all){Text($0.title).tag($0.id)};Text("Do nothing").tag("none")}.labelsHidden().frame(width:170)}
 }
 var devicePage: some View {
  ScrollView {VStack(alignment:.leading,spacing:20) {
   GroupBox {VStack(alignment:.leading,spacing:8) {
    Toggle("Use Quiet Studio for Prompt",isOn:$model.quietStudioPromptIntegrationEnabled)
    Text("Off by default. When enabled, the Genesis Prompt button controls Quiet Studio while the app is open. Otherwise the button keeps its normal native behavior.").font(.caption).foregroundStyle(.secondary)
   }.padding(12)}
   GroupBox {VStack(spacing:18) {
    Toggle("Launch Agent Micro Controller when I sign in",isOn:Binding(get:{model.loginEnabled},set:{model.setLogin($0)}))
    Divider()
    Toggle("Alert sound",isOn:Binding(get:{model.soundEnabled},set:{model.configure(["sound_enabled":$0])})).disabled(!model.supportsSettings)
    HStack {Text("Knob movement");Spacer();Picker("Knob movement",selection:Binding(get:{model.encoderDetents},set:{model.configure(["encoder_detents":$0])})){Text("Every click").tag(1);Text("Every two clicks").tag(2)}.labelsHidden().frame(width:185).disabled(!model.supportsSettings)}
    HStack {Button("Test light and sound"){model.configure(["test_alert":true])}.disabled(!model.supportsSettings || model.mode != "Claude");Spacer();Text(model.firmware).font(.caption.monospaced()).foregroundStyle(.secondary)}
   }.padding(12)}
   Text("Close this window to keep the controller running. Reopen settings from its menu-bar dial icon.").font(.callout).foregroundStyle(.secondary)
   if !model.supportsSettings {Text("The new knob and device settings need firmware v0.2.2 or later.").font(.caption).foregroundStyle(.orange)}
   Text("Built for your Genesis Mini · independent companion for Claude Code").font(.caption).foregroundStyle(.secondary)
  }}
 }
}
@main struct MapperApp: App {
 @StateObject private var model=Model()
 @StateObject private var remote=GenesisRemoteBridge.shared
 var body: some Scene {
  WindowGroup("Agent Micro Controller",id:"controller"){MainView(model:model)}.defaultSize(width:1040,height:740)
  WindowGroup("iPhone Pairing",id:"phone-pairing"){RemotePairingView(bridge:remote)}.defaultSize(width:800,height:760)
  MenuBarExtra("Agent Micro Controller",systemImage:"dial.medium.fill") {ControllerMenu(model:model)}
 }
}
struct ControllerMenu: View {
 @ObservedObject var model:Model
 @Environment(\.openWindow) var openWindow
 var body: some View {Text(model.mode);Button("Open Agent Micro Controller"){openWindow(id:"controller");NSApp.activate()};Button("Pair iPhone / Artifacts"){openWindow(id:"phone-pairing");NSApp.activate()};Button("Refresh sessions"){model.discoverSessions()};Divider();Button("Quit Agent Micro Controller"){NSApp.terminate(nil)}}
}
