/// A small least-recently-used cache for optional, reproducible in-memory data.
/// Eviction never removes user files or persistent settings.
struct BoundedCache<Key: Hashable, Value> {
    private let capacity: Int
    private var values: [Key: Value] = [:]
    private var recency: [Key] = []

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    var count: Int { values.count }

    subscript(key: Key) -> Value? {
        mutating get {
            guard let value = values[key] else { return nil }
            recency.removeAll { $0 == key }
            recency.append(key)
            return value
        }
        set {
            recency.removeAll { $0 == key }
            guard let newValue else {
                values.removeValue(forKey: key)
                return
            }
            values[key] = newValue
            recency.append(key)
            while recency.count > capacity {
                values.removeValue(forKey: recency.removeFirst())
            }
        }
    }
}
