import Foundation
import Darwin
import Security

/// Official queue command only. This does not resume a session, start a daemon,
/// insert into a desktop composer, or acknowledge model delivery.
enum CodexQueuePolicy {
    static let relativeExecutable = "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
    static func executable(in application:URL)->URL? {
        guard Bundle(url:application)?.bundleIdentifier == "com.openai.codex" else{return nil}
        let root=application.resolvingSymlinksInPath().standardizedFileURL
        let candidate=root.appendingPathComponent(relativeExecutable).resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path.hasPrefix(root.path+"/"),FileManager.default.isExecutableFile(atPath:candidate.path),
              let attributes=try? FileManager.default.attributesOfItem(atPath:candidate.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let mode=attributes[.posixPermissions] as? NSNumber,mode.intValue & 0o022 == 0 else{return nil}
        return candidate
    }
    static func isTrustedExecutable(_ executable:URL)->Bool {
        var code:SecStaticCode?,requirement:SecRequirement?
        guard SecStaticCodeCreateWithPath(executable as CFURL,[],&code)==errSecSuccess,let code,
              SecRequirementCreateWithString("anchor apple generic and identifier \"codex\" and certificate leaf[subject.OU] = \"2DC432GLL2\"" as CFString,[],&requirement)==errSecSuccess,let requirement else{return false}
        return SecStaticCodeCheckValidity(code,[],requirement)==errSecSuccess
    }
    static func usesDefaultHome(environment:[String:String],home:URL)->Bool {
        guard let supplied=environment["CODEX_HOME"],!supplied.isEmpty else{return true}
        guard supplied.hasPrefix("/") else{return false}
        return URL(fileURLWithPath:supplied).standardizedFileURL.resolvingSymlinksInPath() == home.appendingPathComponent(".codex").standardizedFileURL.resolvingSymlinksInPath()
    }
    static func environment(home:URL)->[String:String] {
        // Do not inherit alternate account roots, proxy commands, injected
        // credentials, dynamic-library variables or arbitrary PATH entries.
        ["HOME":home.path,"CODEX_HOME":home.appendingPathComponent(".codex").path,
         "USER":NSUserName(),"LOGNAME":NSUserName(),"PATH":"/usr/bin:/bin:/usr/sbin:/sbin",
         "LANG":"en_US.UTF-8","TMPDIR":NSTemporaryDirectory()]
    }
    static func arguments(threadID:String,text:String,inventoryIDs:Set<String>)->[String]? {
        guard let uuid=UUID(uuidString:threadID),uuid.uuidString.lowercased()==threadID,
              inventoryIDs.contains(threadID),!text.unicodeScalars.allSatisfy({$0.properties.isWhitespace}),
              !text.utf8.contains(0),text.utf8.count<=64_000 else{return nil}
        return ["queue","--thread",threadID,"--message="+text]
    }
}

struct CodexQueueResult {
    let status:String
    let message:String
}

enum CodexQueueProcess {
    enum Completion: Equatable {case notLaunched,exited(Int32),interrupted,timedOut}
    struct Execution {let completion:Completion;let output:Data;let truncated:Bool}
    static func acknowledgedQueueID(output:Data,threadID:String)->String? {
        guard let raw=String(data:output,encoding:.utf8) else{return nil}
        let parts=raw.trimmingCharacters(in:.whitespacesAndNewlines).split(separator:" ",omittingEmptySubsequences:false)
        guard parts.count==6,parts[0]=="Queued",parts[1]=="message",let queued=UUID(uuidString:String(parts[2])),
              parts[3]=="for",parts[4]=="thread",parts[5]==threadID+"." else{return nil}
        return queued.uuidString.lowercased()
    }
    static func receipt(_ execution:Execution,threadID:String)->CodexQueueResult {
        switch execution.completion {
        case .notLaunched:
            return CodexQueueResult(status:"failed",message:"Codex’s queue command could not start. Nothing was queued.")
        case .exited(0) where !execution.truncated && acknowledgedQueueID(output:execution.output,threadID:threadID) != nil:
            return CodexQueueResult(status:"queued",message:"Queued for this Codex chat. Delivery has not been confirmed; it may wait until this chat processes pending messages.")
        case .exited:
            // An abnormal exit might occur after the queue write. Even zero
            // requires the exact native acknowledgement for this thread.
            return CodexQueueResult(status:"uncertain",message:"Codex’s queue command ended without confirming acceptance for this chat. Check it before sending this prompt again.")
        case .interrupted,.timedOut:
            return CodexQueueResult(status:"uncertain",message:"Codex’s queue result is unknown. The command was not retried; check the chat before sending this prompt again.")
        }
    }
    static func run(executable:URL,arguments:[String],environment:[String:String],timeout:TimeInterval=5)->Execution {
        func unstarted()->Execution {Execution(completion:.notLaunched,output:Data(),truncated:false)}
        guard !Task.isCancelled,timeout>0,timeout.isFinite else{return unstarted()}
        let process=Process();process.executableURL=executable;process.arguments=arguments;process.environment=environment
        process.standardInput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        // Bounded memory-only acknowledgement. Never log argv/stdout/stderr,
        // and never hold up the child if unexpected output exceeds our cap.
        let pipe=Pipe(),descriptor=pipe.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor,F_SETFL,fcntl(descriptor,F_GETFL)|O_NONBLOCK) >= 0 else{return unstarted()}
        process.standardOutput=pipe
        var output=Data(),truncated=false
        defer{try? pipe.fileHandleForReading.close();try? pipe.fileHandleForWriting.close()}
        func drain() {
            var bytes=[UInt8](repeating:0,count:1024)
            for _ in 0..<64 {
                let count=read(descriptor,&bytes,bytes.count)
                if count<0 && errno==EINTR {continue}
                guard count>0 else{return}
                let room=max(0,4096-output.count),take=min(room,count)
                output.append(contentsOf:bytes.prefix(take))
                if count>room {truncated=true}
            }
        }
        do{try process.run()}catch{return unstarted()}
        try? pipe.fileHandleForWriting.close()
        let deadline=ProcessInfo.processInfo.systemUptime+timeout
        while process.isRunning,ProcessInfo.processInfo.systemUptime<deadline,!Task.isCancelled {drain();Thread.sleep(forTimeInterval:0.02)}
        drain()
        if !process.isRunning {
            return Execution(completion:process.terminationReason == .exit ? .exited(process.terminationStatus):.interrupted,output:output,truncated:truncated)
        }
        let completion:Completion=Task.isCancelled ? .interrupted:.timedOut
        process.terminate()
        let grace=ProcessInfo.processInfo.systemUptime+0.25
        while process.isRunning,ProcessInfo.processInfo.systemUptime<grace {drain();Thread.sleep(forTimeInterval:0.01)}
        if process.isRunning {kill(process.processIdentifier,SIGKILL)}
        // Keep the bridge bounded even if an OS-level stalled process takes
        // longer to reap. The uncertain receipt prohibits automatic replay.
        let reapDeadline=ProcessInfo.processInfo.systemUptime+0.25
        while process.isRunning,ProcessInfo.processInfo.systemUptime<reapDeadline {drain();Thread.sleep(forTimeInterval:0.01)}
        drain()
        return Execution(completion:completion,output:output,truncated:truncated)
    }
    static func enqueue(executable:URL,arguments:[String],home:URL,threadID:String) async ->CodexQueueResult {
        let task=Task.detached(priority:.userInitiated) {
            guard CodexQueuePolicy.isTrustedExecutable(executable) else{return CodexQueueResult(status:"failed",message:"The installed Codex command could not be verified as signed by OpenAI. Nothing was queued.")}
            return receipt(run(executable:executable,arguments:arguments,environment:CodexQueuePolicy.environment(home:home)),threadID:threadID)
        }
        return await withTaskCancellationHandler(operation:{await task.value},onCancel:{task.cancel()})
    }
}
