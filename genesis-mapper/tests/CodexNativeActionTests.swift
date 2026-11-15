import Foundation
import ApplicationServices

@main struct CodexNativeActionTests {
    @MainActor static func main() {
        var checks=0
        func check(_ passed:Bool,_ label:String) {
            checks+=1
            guard passed else {fatalError("Failed: \(label)")}
        }
        typealias Item=CodexNativeActionPolicy.MenuItem
        func item(_ title:String,menu:String="View",enabled:Bool=true,hidden:Bool=false,press:Bool=true,role:String=kAXMenuItemRole)->Item {
            .init(menu:menu,title:title,role:role,enabled:enabled,hidden:hidden,canPress:press)
        }
        let routes=CodexNativeActionPolicy.routes
        let model=CodexNativeActions.descriptors.first{$0.id=="modelAndEffort"}
        check(model?.title=="Change model" && model?.opensNavigation==true,"model picker offers remote menu navigation")
        check(model?.requiresChat==false && model?.changesChat==false,"model picker acts on current Mac view without claiming chat navigation")
        check(CodexNativeActionPolicy.modelPickerKey==46 && CodexNativeActionPolicy.modelPickerModifiers==[.maskControl,.maskShift],"model picker uses only the documented Control Shift M shortcut")
        check(CodexNativeActions.descriptors.filter{$0.id=="modelAndEffort"}.count==1,"model picker has one mapping descriptor")
        check(Set(routes.map(\.id)).count==routes.count,"unique explicit action IDs")
        for route in routes {
            check(CodexNativeActionPolicy.matchingIndex(actionID:route.id,items:[item(route.item,menu:route.menu)])==0,"correct scoped menu for \(route.id)")
            check(CodexNativeActionPolicy.matchingIndex(actionID:route.id,items:[item(route.item,menu:route.menu,enabled:false)])==nil,"disabled action rejected")
        }
        check(CodexNativeActionPolicy.matchingIndex(actionID:"newProject",items:[item("New Project...",menu:"File")])==0,"ellipsis normalization")
        check(CodexNativeActionPolicy.matchingIndex(actionID:"toggleSidebar",items:[item("  Toggle  sidebar  ")])==0,"case and whitespace normalization")
        check(CodexNativeActionPolicy.matchingIndex(actionID:"goBack",items:[item("Back",menu:"Browser")])==nil,"wrong submenu rejected")
        check(CodexNativeActionPolicy.matchingIndex(actionID:"goBack",items:[item("Back to thread")])==nil,"substring cannot match")
        check(CodexNativeActionPolicy.matchingIndex(actionID:"goBack",items:[item("Back"),item("Back")])==nil,"ambiguous duplicate rejected")
        check(CodexNativeActionPolicy.matchingIndex(actionID:"goBack",items:[item("Back",hidden:true)])==nil,"hidden accelerator rejected")
        check(CodexNativeActionPolicy.matchingIndex(actionID:"goBack",items:[item("Back",press:false)])==nil,"unpressable node rejected")
        check(CodexNativeActionPolicy.matchingIndex(actionID:"goBack",items:[item("Back",role:kAXButtonRole)])==nil,"non-menu UI rejected")
        for forbidden in ["approval.approve","approval.decline","composer.submit","composer.startVoiceMode","previousRecentThread","searchChats","deleteChat","git.mergePullRequest","unknown"] {
            check(CodexNativeActionPolicy.matchingIndex(actionID:forbidden,items:[item("Back")])==nil,"unverified or sensitive route rejected")
        }
        check(routes.first{$0.id=="previousSidebarItem"}?.changesChat==true,"navigation invalidates old selection")
        check(routes.allSatisfy{!$0.requiresChat},"native menus act on the Mac view, not a claimed phone chat")
        check(CodexNativeActionPolicy.pageURL(actionID:"openSettings")?.absoluteString=="codex://settings","fixed settings page")
        check(CodexNativeActionPolicy.pageURL(actionID:"openSkills")?.absoluteString=="codex://skills","fixed skills page")
        check(CodexNativeActionPolicy.pageURL(actionID:"newChat")?.absoluteString=="codex://threads/new","documented new chat link works without running app or AX")
        check(!routes.contains{$0.id=="newChat"},"new chat does not depend on native menu visibility")
        check(CodexNativeActionPolicy.pageLinks.count==3,"only three fixed public page routes")
        check(CodexNativeActions.descriptors.filter{$0.id=="newChat"}.count==1,"one new chat descriptor")
        check(CodexNativeActions.descriptors.first{$0.id=="newChat"}?.changesChat==true,"new chat clears old phone destination")
        check(CodexNativeActions.descriptors.allSatisfy{RemotePolicy.commands.contains($0.id)},"every advertised action is allowed by the real host protocol")
        for input in ["codex://settings","openSettings?name=remote","openSkills/execute","composer.submit","plugins/install","openMicroSettings","newChat?prompt=send","codex://threads/new"] {
            check(CodexNativeActionPolicy.pageURL(actionID:input)==nil,"arbitrary page/operation rejected")
        }
        print("PASS: \(checks) Codex native menu policy checks; no live app action performed.")
    }
}
