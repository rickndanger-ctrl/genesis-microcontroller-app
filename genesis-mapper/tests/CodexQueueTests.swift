import Foundation

@main struct CodexQueueTests {
    static func main() {
        var checks=0
        func check(_ value:Bool,_ label:String) {checks+=1;guard value else{fatalError("Failed: "+label)}}
        let thread="01a130bc-ebfa-7c92-b84e-5d66a3bc7979",queued="01a130bc-ebfa-7c92-b84e-5d66a3bc7970"
        let text="--literal $HOME `command`\nnext line 🐦"
        let arguments=CodexQueuePolicy.arguments(threadID:thread,text:text,inventoryIDs:[thread])
        check(arguments==["queue","--thread",thread,"--message="+text],"literal prompt stays one attached flag argument, including leading dash")
        check(arguments?.contains("--resume")==false,"never resumes or takes ownership")
        check(CodexQueuePolicy.arguments(threadID:thread,text:text,inventoryIDs:[])==nil,"fresh account inventory membership required")
        for invalid in ["name",thread+"/new",thread+"?text=x",thread.uppercased()] {
            check(CodexQueuePolicy.arguments(threadID:invalid,text:text,inventoryIDs:[invalid])==nil,"exact canonical UUID only")
        }
        for invalid in [""," \n\t","a\0b",String(repeating:"a",count:64_001)] {
            check(CodexQueuePolicy.arguments(threadID:thread,text:invalid,inventoryIDs:[thread])==nil,"invalid prompt rejected before launch")
        }
        let home=URL(fileURLWithPath:"/Users/fixture",isDirectory:true)
        check(CodexQueuePolicy.usesDefaultHome(environment:[:],home:home),"default account root allowed")
        check(CodexQueuePolicy.usesDefaultHome(environment:["CODEX_HOME":"/Users/fixture/.codex"],home:home),"explicit same default account root allowed")
        check(!CodexQueuePolicy.usesDefaultHome(environment:["CODEX_HOME":"/tmp/other-account"],home:home),"alternate inherited account root blocked")
        check(!CodexQueuePolicy.usesDefaultHome(environment:["CODEX_HOME":"relative"],home:home),"relative account root blocked")
        let environment=CodexQueuePolicy.environment(home:home)
        check(environment["CODEX_HOME"]=="/Users/fixture/.codex" && environment["HOME"]==home.path,"queue uses same default inventory root")
        check(environment["OPENAI_API_KEY"]==nil && environment["DYLD_INSERT_LIBRARIES"]==nil && environment["PATH"]=="/usr/bin:/bin:/usr/sbin:/sbin","child environment excludes credentials and custom executables")
        check(!CodexQueuePolicy.isTrustedExecutable(URL(fileURLWithPath:"/bin/sh")),"only OpenAI signed codex can execute production queue")
        let acknowledgement="Queued message \(queued) for thread \(thread).\n"
        check(CodexQueueProcess.acknowledgedQueueID(output:Data(acknowledgement.utf8),threadID:thread)==queued,"exact official queued acknowledgment accepted")
        for invalid in ["",acknowledgement+"extra",acknowledgement.replacingOccurrences(of:thread,with:queued),"Queued message wrong for thread \(thread).",text] {
            check(CodexQueueProcess.acknowledgedQueueID(output:Data(invalid.utf8),threadID:thread)==nil,"unknown or wrong-thread stdout never confirms queue")
        }
        func result(_ completion:CodexQueueProcess.Completion,_ output:String=acknowledgement,_ truncated:Bool=false)->CodexQueueResult {
            CodexQueueProcess.receipt(.init(completion:completion,output:Data(output.utf8),truncated:truncated),threadID:thread)
        }
        check(result(.exited(0)).status=="queued","successful acknowledgment is queued, never delivered")
        check(result(.notLaunched).status=="failed","failure before process start is definite")
        for completion:CodexQueueProcess.Completion in [.exited(1),.exited(2),.timedOut,.interrupted] {
            check(result(completion).status=="uncertain","launched ambiguous result is not safe to retry")
            check(!result(completion,text).message.contains(text),"receipt never echoes diagnostic prompt text")
        }
        check(result(.exited(0),"unexpected").status=="uncertain","zero exit alone does not acknowledge target")
        check(result(.exited(0),acknowledgement,true).status=="uncertain","truncated output cannot confirm")
        // Isolated subprocess fixtures; no Codex process, app, chat or network.
        let shell=URL(fileURLWithPath:"/bin/sh"),fixtureEnv=["PATH":"/usr/bin:/bin"]
        let accepted=CodexQueueProcess.run(executable:shell,arguments:["-c","printf '%s\\n' \"$1\"","fixture",String(acknowledgement.dropLast())],environment:fixtureEnv)
        check(CodexQueueProcess.receipt(accepted,threadID:thread).status=="queued","subprocess acknowledgment and exact target verified")
        let rejected=CodexQueueProcess.run(executable:shell,arguments:["-c","exit 2"],environment:fixtureEnv)
        check(rejected.completion == .exited(2),"nonzero exit captured without retry")
        let missing=CodexQueueProcess.run(executable:URL(fileURLWithPath:"/nonexistent/genesis-fixture"),arguments:[],environment:fixtureEnv)
        check(missing.completion == .notLaunched,"unspawned executable known rejection")
        let start=ProcessInfo.processInfo.systemUptime
        let timeout=CodexQueueProcess.run(executable:shell,arguments:["-c","exec /bin/sleep 5"],environment:fixtureEnv,timeout:0.1)
        check(timeout.completion == .timedOut && ProcessInfo.processInfo.systemUptime-start<2,"timeout is bounded and uncertain")
        let oversized=CodexQueueProcess.run(executable:shell,arguments:["-c","/usr/bin/head -c 12000 /dev/zero"],environment:fixtureEnv)
        check(oversized.output.count==4096 && oversized.truncated,"stdout memory is bounded while child drains")
        if CommandLine.arguments.contains("--verify-installed-cli") {
            let app=URL(fileURLWithPath:"/Applications/ChatGPT.app",isDirectory:true)
            let binary=CodexQueuePolicy.executable(in:app)
            check(binary != nil,"known installed Codex bundle resolves exact executable")
            check(binary.map(CodexQueuePolicy.isTrustedExecutable)==true,"installed native CLI satisfies OpenAI signature requirement")
        }
        print("PASS \(checks) Codex queue policy and isolated process checks; no live Codex action performed")
    }
}
