import Foundation

/// Native Open panels have their own focus tree and contain a sidebar before the files.
/// These identifiers come from the native panel, not filenames or conversation text.
enum FilePickerPolicy {
    enum IconStep:Equatable {case key(UInt16),target(Int),vertical(UInt16),blocked}
    static func sameIconRow(_ a:Double,_ b:Double)->Bool {abs(a-b)<8}
    static func iconStep(rows:[Double],current:Int?,direction:Int)->IconStep {
        guard !rows.isEmpty,direction == -1 || direction == 1 else{return .blocked}
        guard let current,rows.indices.contains(current) else{return .target(direction>0 ? 0:rows.count-1)}
        let next=current+direction
        guard rows.indices.contains(next) else{return .vertical(direction>0 ? 125:126)}
        return sameIconRow(rows[current],rows[next]) ? .key(direction>0 ? 124:123):.target(next)
    }
    static func isIconView(identifier:String)->Bool {identifier=="IconView"}
    static func turnKey(identifier:String,direction:Int)->UInt16? {
        guard direction == -1 || direction == 1 else{return nil}
        return isIconView(identifier:identifier) ? (direction>0 ? 124:123):(direction>0 ? 125:126)
    }
    static func backToLocations(column:Int?)->Bool {column == nil || column == 0}
    static func isLocationRow(role:String,expanded:Bool,disclosedRows:Int,enabled:Bool=true)->Bool {
        role == "AXRow" && enabled && !expanded && disclosedRows==0
    }
    static func locationIndex(count:Int,current:Int?,direction:Int)->Int? {
        guard count>0,direction == -1 || direction == 1 else{return nil}
        guard let current,current>=0,current<count else{return direction>0 ? 0:count-1}
        return (current+direction+count)%count
    }
    enum Selection {case folder,file,unknown}
    enum ColumnAction:Equatable {case arrowRight,arrowLeft,openFile,focusLocations,focusFiles,blocked}
    static func columnAction(select:Bool,inLocations:Bool,column:Int?,selection:Selection)->ColumnAction {
        if inLocations {return select ? .focusFiles:.blocked}
        guard let column,column>=0 else{return .blocked}
        if !select {return column==0 ? .focusLocations:.arrowLeft}
        switch selection {
        case .folder:return .arrowRight
        case .file:return .openFile
        case .unknown:return .blocked
        }
    }
    enum Delivery {case blocked,application,systemFocus}
    static func delivery(nativeOpenPanel:Bool,ownerPID:Int32,frontPID:Int32?,currentSession:Bool)->Delivery {
        guard currentSession,ownerPID>0,frontPID==ownerPID else{return .blocked}
        return nativeOpenPanel ? .systemFocus:.application
    }
    static func isOpenPanel(role:String,identifier:String)->Bool {
        ["AXSheet","AXWindow","AXDialog"].contains(role) && identifier=="open-panel"
    }
    static func contentPriority(role:String,identifier:String,description:String)->Int {
        let label=(identifier+" "+description).lowercased()
        guard !label.contains("sidebar") else{return 0}
        if isIconView(identifier:identifier) {return 4}
        if role=="AXBrowser" {return 4}
        if role=="AXOutline" || role=="AXTable" {return 3}
        if role=="AXList" {return 2}
        return 0
    }
}
