import Foundation

struct NativeControl: Identifiable, Equatable {
    let id:String
    let title:String
    let detail:String
    let enabled:Bool
    let isTalk:Bool
    let isSend:Bool
    init(id:String,title:String,detail:String,enabled:Bool,isTalk:Bool=false,isSend:Bool=false) {self.id=id;self.title=title;self.detail=detail;self.enabled=enabled;self.isTalk=isTalk;self.isSend=isSend}
}
// Native settings stay owned by Codex. The companion only mirrors labels and slot kinds.
enum CodexControls {
    static let keys=["ACT06","ACT07","ACT08","ACT09","ACT12","ACT10","ACT11","JOY_UP","JOY_RIGHT","JOY_DOWN","JOY_LEFT","DIAL"]
    static let capNames:[String:String] = ["FAST":"Fast mode","APPR":"Approve","REJ":"Decline","SPLIT":"Fork chat","MIC":"Hold to talk","MIC1":"Hold to talk","CODEX":"Send prompt","BUG":"Feedback","OAI":"OpenAI docs","TERM":"Terminal","DWN":"Copy chat","DEL":"Archive chat","NEW":"New chat","NAV":"Browser tab","MAGIC":"Toggle pin","DIFF":"Changes","PLAY":"Run action","GIT":"Commit options","BRCH":"Draft PR","BRANCH":"New branch","MRG":"Merge PR","PR":"Create PR","PAINT":"Add photos","LAB":"Settings","PARTY":"Side chat","TIME":"Scheduled tasks","MIND+":"More reasoning","MIND-":"Less reasoning","SETUP":"Settings","FOLD":"Open folder","UPL":"Add files","APPS":"Skills","YOLO":"Type :yolo:","YEET":"Type :yeet:"]
    static func sections(_ config:String) -> [String:[String:String]] {
        var result=[String:[String:String]](), section=""
        for raw in config.components(separatedBy:.newlines) {
            let line=raw.trimmingCharacters(in:.whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {section=String(line.dropFirst().dropLast());continue}
            guard section.hasPrefix("desktop.codex-micro-layout"),let equal=line.firstIndex(of:"=") else {continue}
            let key=String(line[..<equal]).trimmingCharacters(in:.whitespaces)
            let rawValue=String(line[line.index(after:equal)...]).trimmingCharacters(in:.whitespaces)
            var value=rawValue
            if value.hasPrefix("\"") {
                // JSON-compatible quoted values cover the strings written by Codex's serializer.
                let scanner=Array(value);var escaped=false;var end:Int?
                for i in 1..<scanner.count {if escaped {escaped=false;continue};if scanner[i]=="\\" {escaped=true;continue};if scanner[i]=="\"" {end=i;break}}
                guard let end,let data=String(scanner[0...end]).data(using:.utf8),let parsed=try? JSONDecoder().decode(String.self,from:data) else {continue};value=parsed
            } else if value.hasPrefix("'") {guard let end=value.dropFirst().firstIndex(of:"'") else {continue};value=String(value[value.index(after:value.startIndex)..<end])}
            else {value=value.components(separatedBy:"#")[0].trimmingCharacters(in:.whitespaces)}
            result[section,default:[:]][key]=value
        }
        return result
    }
    static func read(_ config:String) -> [NativeControl] {
        let sections=sections(config),base="desktop.codex-micro-layout"
        let separate=sections[base]?["separateMicrophoneKeys"]=="true"
        func assigned(_ path:String,fallback:String) -> (String,Bool) {
            let entry=sections[path] ?? [:], action=sections[path+".action"] ?? entry
            if action["type"]=="skill" {return ("Skill: "+(action["skillName"] ?? "custom"),true)}
            if action["type"]=="composer-text" {return ("Insert text",true)}
            if let command=action["commandId"] ?? entry["commandId"] {return (NativeCommandNames.titles[command] ?? command,true)}
            if let cap=entry["keycapId"] {return (capNames[cap] ?? "Unassigned",capNames[cap] != nil)}
            return (fallback,false)
        }
        return keys.map {key in
            if key=="DIAL" {return NativeControl(id:key,title:"Native dial",detail:sections[base]?["encoderMode"] ?? "Use Codex dial settings",enabled:true)}
            if key.hasPrefix("JOY_") {
                let direction=String(key.dropFirst(4)).lowercased(), path=base+".analogStick."+direction
                let (title,enabled)=assigned(path,fallback:"Stick "+direction)
                return NativeControl(id:key,title:title,detail:"Analog stick · "+direction,enabled:enabled)
            }
            if key=="ACT11" && !separate {return NativeControl(id:key,title:"Second mic key",detail:"Enable separate microphone keys in Codex to use this control.",enabled:false)}
            let path=base+".slots."+(key=="ACT10" && !separate ? "ACT10_ACT11":key)
            var (title,enabled)=assigned(path,fallback:key)
            if title=="Hold to talk" && sections[base]?["voiceButtonMode"]=="realtime" {title="Voice chat"}
            if key=="ACT10" && !enabled {title="Hold to talk";enabled=true}
            let entry=sections[path] ?? [:],action=sections[path+".action"] ?? [:]
            let command=action["commandId"] ?? entry["commandId"],cap=entry["keycapId"] ?? ""
            let defaultAction=command==nil && action.isEmpty
            let talk=defaultAction && ["MIC","MIC1"].contains(cap) && sections[base]?["voiceButtonMode"] != "realtime"
            let send=command=="composer.submit" || (defaultAction && cap=="CODEX")
            return NativeControl(id:key,title:title,detail:key+" · configured in Codex Micro",enabled:enabled,isTalk:talk,isSend:send)
        }
    }
    static func current() -> [NativeControl] {
        let home=ProcessInfo.processInfo.environment["CODEX_HOME"].map{URL(fileURLWithPath:$0)} ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return read((try? String(contentsOf:home.appendingPathComponent("config.toml"),encoding:.utf8)) ?? "")
    }
    static func screenLabel(_ label:String) -> String {
        let ascii=label.folding(options:.diacriticInsensitive,locale:Locale(identifier:"en_US_POSIX"))
            .replacingOccurrences(of:"…",with:"...").replacingOccurrences(of:"·",with:"-")
            .unicodeScalars.filter{$0.value>=32 && $0.value<=126}
        let result=String(String.UnicodeScalarView(ascii)).prefix(25)
        return result.isEmpty ? "Custom action" : String(result)
    }
}
