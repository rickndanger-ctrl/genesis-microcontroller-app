@main struct ReadSnapshotCacheTests {
    static func main() {
        struct Read {let value:String?}
        enum Failure:Error {case fixture}
        let cache=ReadSnapshotCache<String,Read>()
        var reads=0,live="first"
        func fetch(_ key:String)->String? {
            if let found=cache[key] {return found.value}
            reads+=1
            let value=key=="missing" ? nil:live
            cache[key]=Read(value:value)
            return value
        }
        precondition(fetch("title")=="first" && fetch("title")=="first" && reads==2,"outside snapshots every UI read stays fresh")
        cache.withSnapshot {
            precondition(fetch("title")=="first")
            live="changed"
            precondition(fetch("title")=="first" && reads==3,"one read-only snapshot reuses a repeated attribute")
            cache.withSnapshot {precondition(fetch("title")=="first" && reads==3,"nested synchronous reads share the same snapshot")}
            precondition(fetch("missing")==nil && fetch("missing")==nil && reads==4,"missing attributes can be cached inside the snapshot")
        }
        precondition(cache["title"]==nil,"snapshot exit clears all cached attributes")
        cache.withSnapshot {precondition(fetch("title")=="changed" && reads==5,"the next snapshot sees changed UI state")}
        do {
            try cache.withSnapshot {cache["title"]=Read(value:"stale");throw Failure.fixture}
        } catch {}
        precondition(cache["title"]==nil && fetch("title")=="changed" && reads==6,"throwing out of a snapshot still clears stale state")
        print("PASS 7 synchronous read-cache lifetime and fresh-state checks")
    }
}
