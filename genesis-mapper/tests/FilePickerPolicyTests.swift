import Foundation

@main struct FilePickerPolicyTests {
    static func main() {
        // Reproduced native Claude Open sheet; detection must not depend on walking
        // hundreds of filenames before finding the Cancel/Open buttons.
        precondition(FilePickerPolicy.isOpenPanel(role:"AXSheet",identifier:"open-panel"))
        precondition(!FilePickerPolicy.isOpenPanel(role:"AXSheet",identifier:"save-panel"))
        precondition(!FilePickerPolicy.isOpenPanel(role:"AXTextArea",identifier:"open-panel"))
        precondition(!FilePickerPolicy.isOpenPanel(role:"AXGroup",identifier:""))
        let columns=[("AXOutline","","sidebar"),("AXBrowser","ColumnView","column view")]
        let ranked=columns.map{FilePickerPolicy.contentPriority(role:$0.0,identifier:$0.1,description:$0.2)}
        precondition(ranked[0]==0 && ranked[1]>0)
        for role in ["AXOutline","AXTable","AXList"] {
            precondition(FilePickerPolicy.contentPriority(role:role,identifier:"sidebar",description:"")==0)
            precondition(FilePickerPolicy.contentPriority(role:role,identifier:"files",description:"")>0)
        }
        precondition(FilePickerPolicy.contentPriority(role:"AXTextField",identifier:"",description:"Search")==0)
        precondition(FilePickerPolicy.contentPriority(role:"AXButton",identifier:"OKButton",description:"")==0)
        // Native picker keyboard delivery must use the system's focused panel,
        // while ordinary menus stay PID-targeted. No delivery after focus/session loss.
        precondition(FilePickerPolicy.delivery(nativeOpenPanel:true,ownerPID:10,frontPID:10,currentSession:true) == .systemFocus)
        precondition(FilePickerPolicy.delivery(nativeOpenPanel:false,ownerPID:10,frontPID:10,currentSession:true) == .application)
        for native in [false,true] {
            precondition(FilePickerPolicy.delivery(nativeOpenPanel:native,ownerPID:10,frontPID:11,currentSession:true) == .blocked)
            precondition(FilePickerPolicy.delivery(nativeOpenPanel:native,ownerPID:10,frontPID:nil,currentSession:true) == .blocked)
            precondition(FilePickerPolicy.delivery(nativeOpenPanel:native,ownerPID:10,frontPID:10,currentSession:false) == .blocked)
            precondition(FilePickerPolicy.delivery(nativeOpenPanel:native,ownerPID:0,frontPID:0,currentSession:true) == .blocked)
        }
        precondition(FilePickerPolicy.columnAction(select:true,inLocations:false,column:0,selection:.folder) == .arrowRight)
        precondition(FilePickerPolicy.columnAction(select:true,inLocations:false,column:3,selection:.file) == .openFile)
        precondition(FilePickerPolicy.columnAction(select:true,inLocations:false,column:1,selection:.unknown) == .blocked)
        precondition(FilePickerPolicy.columnAction(select:false,inLocations:false,column:1,selection:.unknown) == .arrowLeft)
        precondition(FilePickerPolicy.columnAction(select:false,inLocations:false,column:0,selection:.file) == .focusLocations)
        precondition(FilePickerPolicy.columnAction(select:true,inLocations:true,column:nil,selection:.unknown) == .focusFiles)
        precondition(FilePickerPolicy.columnAction(select:false,inLocations:true,column:nil,selection:.unknown) == .blocked)
        precondition(FilePickerPolicy.columnAction(select:true,inLocations:false,column:nil,selection:.file) == .blocked)
        precondition(FilePickerPolicy.locationIndex(count:8,current:7,direction:1)==0)
        precondition(FilePickerPolicy.locationIndex(count:8,current:0,direction:-1)==7)
        precondition(FilePickerPolicy.locationIndex(count:8,current:3,direction:1)==4)
        precondition(FilePickerPolicy.locationIndex(count:8,current:nil,direction:1)==0)
        precondition(FilePickerPolicy.locationIndex(count:0,current:nil,direction:1)==nil)
        precondition(FilePickerPolicy.locationIndex(count:8,current:3,direction:0)==nil)
        // Recorded native sidebar: headings and places expose identical actions
        // and report AXSelected settable; only heading disclosure distinguishes them.
        precondition(!FilePickerPolicy.isLocationRow(role:"AXRow",expanded:true,disclosedRows:4))
        precondition(!FilePickerPolicy.isLocationRow(role:"AXRow",expanded:false,disclosedRows:4))
        precondition(FilePickerPolicy.isLocationRow(role:"AXRow",expanded:false,disclosedRows:0))
        precondition(!FilePickerPolicy.isLocationRow(role:"AXColumn",expanded:false,disclosedRows:0))
        let raw = [(false,0),(false,0),(true,4),(false,0),(false,0),(false,0),(false,0),(true,4),(false,0),(false,0),(false,0),(false,0),(true,8)]
        let places=raw.enumerated().filter {FilePickerPolicy.isLocationRow(role:"AXRow",expanded:$0.element.0,disclosedRows:$0.element.1)}.map(\.offset)
        let downloads=places.firstIndex(of:6)!
        precondition(places[FilePickerPolicy.locationIndex(count:places.count,current:downloads,direction:1)!]==8)
        precondition(FilePickerPolicy.backToLocations(column:nil))
        precondition(FilePickerPolicy.backToLocations(column:0))
        precondition(!FilePickerPolicy.backToLocations(column:1))
        // Native icon view exposes a collection/section/image hierarchy.
        precondition(FilePickerPolicy.contentPriority(role:"AXCollection",identifier:"IconView",description:"icon view")>0)
        precondition(FilePickerPolicy.contentPriority(role:"AXCollection",identifier:"unrelated",description:"")==0)
        precondition(FilePickerPolicy.turnKey(identifier:"IconView",direction:1)==124)
        precondition(FilePickerPolicy.turnKey(identifier:"IconView",direction:-1)==123)
        precondition(FilePickerPolicy.turnKey(identifier:"ListView",direction:1)==125)
        precondition(FilePickerPolicy.turnKey(identifier:"ColumnView",direction:-1)==126)
        precondition(FilePickerPolicy.turnKey(identifier:"IconView",direction:0)==nil)
        let iconRows:[Double]=[10,10,10,90,90,90,170]
        precondition(FilePickerPolicy.iconStep(rows:iconRows,current:1,direction:1) == .key(124))
        precondition(FilePickerPolicy.iconStep(rows:iconRows,current:2,direction:1) == .target(3))
        precondition(FilePickerPolicy.iconStep(rows:iconRows,current:3,direction:-1) == .target(2))
        precondition(FilePickerPolicy.iconStep(rows:iconRows,current:5,direction:1) == .target(6))
        precondition(FilePickerPolicy.iconStep(rows:iconRows,current:6,direction:1) == .vertical(125))
        precondition(FilePickerPolicy.iconStep(rows:iconRows,current:0,direction:-1) == .vertical(126))
        precondition(FilePickerPolicy.iconStep(rows:[],current:nil,direction:1) == .blocked)
        precondition(FilePickerPolicy.iconStep(rows:iconRows,current:2,direction:0) == .blocked)
        precondition(!FilePickerPolicy.isLocationRow(role:"AXRow",expanded:false,disclosedRows:0,enabled:false))
        print("File picker policy: native panel and sidebar exclusion regressions passed")
    }
}
