import Foundation

/// Holds parsed trees for the lifetime of stages 3–7 so each file is parsed once, then
/// evicts. Single-consumer (the pipeline drives stages sequentially); a lock guards
/// incidental access. Eviction is insertion-order with a soft cap — tuning is deferred to
/// M8, and for Phase 1 corpora the whole set fits comfortably.
public final class ASTCache {
    private let parserFactory: () throws -> TreeSitterParser
    private let capacity: Int
    private var order: [String] = []
    private var entries: [String: ParsedTree] = [:]
    private let lock = NSLock()

    public init(capacity: Int = 4096, parserFactory: @escaping () throws -> TreeSitterParser) {
        self.capacity = capacity
        self.parserFactory = parserFactory
    }

    public convenience init(language support: any LanguageSupport, capacity: Int = 4096) {
        self.init(capacity: capacity, parserFactory: { try TreeSitterParser(support) })
    }

    public func insert(_ tree: ParsedTree) {
        lock.lock(); defer { lock.unlock() }
        store(tree)
    }

    /// Returns the cached tree, parsing (and caching) it from disk on a miss.
    public func entry(fileId: String, relPath: String, source: Data) throws -> ParsedTree? {
        lock.lock(); defer { lock.unlock() }
        if let hit = entries[fileId] { return hit }
        guard let parsed = try parserFactory().parse(
            fileId: fileId, relPath: relPath, source: source
        ) else { return nil }
        store(parsed)
        return parsed
    }

    public func evict(fileId: String) {
        lock.lock(); defer { lock.unlock() }
        entries[fileId] = nil
        order.removeAll { $0 == fileId }
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
        order.removeAll()
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    private func store(_ tree: ParsedTree) {
        if entries[tree.fileId] == nil { order.append(tree.fileId) }
        entries[tree.fileId] = tree
        while order.count > capacity {
            let victim = order.removeFirst()
            entries[victim] = nil
        }
    }
}
