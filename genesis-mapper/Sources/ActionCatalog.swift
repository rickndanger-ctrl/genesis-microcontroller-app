import Foundation

struct ControllerAction: Identifiable, Equatable {
    let id: String
    let title: String
    let group: String
    let detail: String
    let sessionRequired: Bool
    let labels: [String]
    let prefixes: [String]
    let menu: String?
    init(_ id:String,_ title:String,_ group:String,_ detail:String, session:Bool = true, labels:[String] = [], prefixes:[String] = [], menu:String? = nil) {
        self.id=id;self.title=title;self.group=group;self.detail=detail;sessionRequired=session;self.labels=labels;self.prefixes=prefixes;self.menu=menu
    }
    static let all:[ControllerAction] = [
        .init("send","Send prompt","Compose","Send the draft in the current chat."),
        .init("dictate","Hold to talk","Compose","Click to start or stop dictation. Keep Claude’s Hold to record off."),
        .init("stop","Stop response","Compose","Stop the current response, when Claude shows Stop.",labels:["Stop"]),
        .init("focus","Focus prompt","Compose","Put the cursor in the current prompt field."),
        .init("attach","Add attachment","Compose","Open the Add menu; you choose the file.",labels:["Add"]),
        .init("model","Model & effort","Compose","Open the model and effort chooser.",prefixes:["Model:"]),
        .init("permissions","Permissions","Compose","Open the permission chooser. Does not approve a request or change access.",labels:["Bypass permissions","Ask permissions","Auto accept edits"],prefixes:["Permissions:"]),
        .init("usage","Usage limits","Compose","Open Claude’s usage information.",prefixes:["Usage:"]),
        .init("new","New session","Navigate","Open a new session without sending anything.",session:false,labels:["New Session"],menu:"File"),
        .init("newwindow","New window","Navigate","Open a new session in another window.",session:false,labels:["New Session in New Window"],menu:"File"),
        .init("sidechat","New side chat","Navigate","Open Claude’s side chat.",session:false,labels:["New Side Chat"],menu:"File"),
        .init("search","Search chats","Navigate","Open Claude’s session search.",session:false,labels:["Search…"],menu:"Go"),
        .init("previous","Previous chat","Navigate","Go to the previous Claude session.",session:false,labels:["Previous Session"],menu:"Go"),
        .init("next","Next chat","Navigate","Go to the next Claude session.",session:false,labels:["Next Session"],menu:"Go"),
        .init("back","Go back","Navigate","Go back in Claude’s navigation history.",session:false,labels:["Back"],menu:"Go"),
        .init("forward","Go forward","Navigate","Go forward in Claude’s navigation history.",session:false,labels:["Forward"],menu:"Go"),
        .init("reopen","Reopen session","Navigate","Reopen the last closed session.",session:false,labels:["Reopen Closed Session"],menu:"File"),
        .init("sidebar","Toggle sidebar","Panels","Show or hide Claude’s sidebar.",session:false,labels:["Show sidebar","Hide sidebar"]),
        .init("terminal","Terminal","Panels","Show or hide the session terminal.",labels:["Terminal"]),
        .init("browser","Browser","Panels","Show or hide the session browser.",labels:["Browser"]),
        .init("changes","Changes","Panels","Show or hide the changes panel.",labels:["Changes"]),
        .init("files","Files","Panels","Show or hide the file panel.",labels:["Files"]),
        .init("details","Session details","Panels","Show or hide the session detail rail.",labels:["Session rail"]),
        .init("view","View options","Panels","Open Claude’s layout options.",session:false,labels:["View options"]),
        .init("rename","Rename session","Session","Open the current chat’s rename field."),
        .init("options","Session options","Session","Open the current chat menu. Choose pin, archive or other options in Claude.")
    ]
    /// Claude names its permission chooser after the mode in use and adds modes
    /// over time, so a list of names goes stale. It is found by position
    /// instead: the one other chooser in the composer row that holds exactly
    /// one "Model:" chooser. Anything less certain returns nil.
    static func permissionChooser(among row:[(role:String,text:String)]) -> Int? {
        func chooser(_ item:(role:String,text:String)) -> Bool {item.role=="AXPopUpButton" && !item.text.isEmpty}
        guard row.filter({chooser($0) && $0.text.hasPrefix("Model:")}).count==1 else {return nil}
        let others=row.indices.filter {chooser(row[$0]) && !row[$0].text.hasPrefix("Model:") && !row[$0].text.hasPrefix("Usage:")}
        return others.count==1 ? others[0] : nil
    }
    static let groups=["Compose","Navigate","Panels","Session"]
    static func find(_ id:String)->ControllerAction? {all.first{$0.id==id}}
    // Keep Send immediately left of dictation. Unknown or duplicate saved IDs are discarded.
    static func menu(_ saved:[String]?) -> [String] {
        let extra=(saved ?? all.map(\.id)).filter{$0 != "send" && $0 != "dictate" && find($0) != nil}
        var result=["send","dictate"]
        for id in extra where !result.contains(id) {result.append(id)}
        return result
    }
}
