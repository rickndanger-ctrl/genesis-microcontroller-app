// A cache for one synchronous, read-only operation. It cannot keep cached UI
// state across an await, and outer-scope exit clears values even on an error.
final class ReadSnapshotCache<Key:Hashable,Value> {
    private var depth=0
    private var values=[Key:Value]()

    func withSnapshot<Result>(_ read:() throws -> Result) rethrows -> Result {
        if depth==0 {values.removeAll(keepingCapacity:true)}
        depth+=1
        defer {
            depth-=1
            if depth==0 {values.removeAll(keepingCapacity:true)}
        }
        return try read()
    }

    subscript(key:Key)->Value? {
        get {depth>0 ? values[key]:nil}
        set {if depth>0 {values[key]=newValue}}
    }
}
