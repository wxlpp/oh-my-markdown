/// Immutable, height-balanced UTF-8 chunks. Copies share all existing text.
/// Appends and suffix reads visit only the insertion path and requested chunks.
package struct IncrementalSourceBuffer {
    package enum BufferError: Error, Equatable { case invalidUTF8, invalidBoundary, sizeOverflow }

    fileprivate final class Node: Sendable {
        let left: Node?
        let right: Node?
        let text: String?
        let count: Int
        let height: Int

        init(text: String) {
            self.left = nil
            self.right = nil
            self.text = text
            self.count = text.utf8.count
            self.height = 1
        }

        init(left: Node, right: Node) {
            self.left = left
            self.right = right
            self.text = nil
            self.count = left.count + right.count
            self.height = max(left.height, right.height) + 1
        }
    }

    package final class Origin: Sendable, Equatable {
        package static func == (lhs: Origin, rhs: Origin) -> Bool {
            lhs === rhs
        }
    }

    /// Retain the immutable owner: an address alone can be reused after a reset.
    package struct Witness: Equatable {
        fileprivate let node: Node
        package static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.node === rhs.node
        }
    }

    private var root: Node?
    private var terminal: Node?
    package let origin = Origin()
    package private(set) var recorder: ParseWorkRecorder?
    private var pending: [UInt8] = []
    package var utf8Count: Int {
        self.root?.count ?? 0
    }

    package var pendingByteCount: Int {
        self.pending.count
    }

    package init(recorder: ParseWorkRecorder? = nil) {
        self.recorder = recorder
    }

    package func recordingFacades(with recorder: ParseWorkRecorder) -> Self {
        var copy = self; copy.recorder = recorder; return copy
    }

    /// Appends create fresh leaves. Matching the terminal leaf of an older
    /// prefix therefore validates append provenance without rereading its text.
    package func witness(at boundary: Int) -> Witness? {
        if boundary == self.utf8Count, let terminal { return Witness(node: terminal) }
        guard boundary > 0, boundary <= self.utf8Count, var node = self.root else { return nil }
        var local = boundary
        while let left = node.left, let right = node.right {
            if local <= left.count { node = left }
            else { local -= left.count; node = right }
        }
        return local == node.count ? Witness(node: node) : nil
    }

    package func byte(at index: Int) -> UInt8? {
        guard index >= 0, index < self.utf8Count, var node = self.root else { return nil }
        var local = index
        while let left = node.left, let right = node.right {
            if local < left.count { node = left }
            else { local -= left.count; node = right }
        }
        guard let bytes = node.text?.utf8 else { return nil }
        return bytes[bytes.index(bytes.startIndex, offsetBy: local)]
    }

    package mutating func append(_ chunk: String, metrics: inout ParseWorkMetrics) throws {
        try Task.checkCancellation()
        guard self.pending.isEmpty else {
            metrics.materializationBytes = ParseWorkMetrics.saturatingAdd(metrics.materializationBytes, chunk.utf8.count)
            try self.append(bytes: Array(chunk.utf8), metrics: &metrics)
            return
        }
        guard !chunk.isEmpty else { return }
        guard self.utf8Count <= Int.max - chunk.utf8.count else { throw BufferError.sizeOverflow }
        let leaf = Node(text: chunk)
        self.terminal = leaf
        metrics.recordMetadata(MemoryLayout<Node>.stride)
        metrics.recordMetadata(2 * MemoryLayout<Node?>.stride + MemoryLayout<String?>.stride + 2 * MemoryLayout<Int>.stride)
        self.root = Self.join(self.root, leaf, metrics: &metrics)
    }

    /// Accept transport bytes without repairing an incomplete scalar. A malformed
    /// append fails atomically; a valid incomplete suffix (at most 3 bytes) waits.
    package mutating func append(bytes: [UInt8], metrics: inout ParseWorkMetrics) throws {
        try Task.checkCancellation()
        var combined = self.pending
        combined.append(contentsOf: bytes)
        metrics.materializationBytes = ParseWorkMetrics.saturatingAdd(metrics.materializationBytes, combined.count)
        var cursor = 0
        var complete = 0
        while cursor < combined.count {
            if cursor & 1023 == 0 { try Task.checkCancellation() }
            let first = combined[cursor]
            metrics.scannerBytes = ParseWorkMetrics.saturatingAdd(metrics.scannerBytes, 1)
            let length: Int
            switch first {
            case 0 ... 0x7F: length = 1
            case 0xC2 ... 0xDF: length = 2
            case 0xE0 ... 0xEF: length = 3
            case 0xF0 ... 0xF4: length = 4
            default: throw BufferError.invalidUTF8
            }
            let available = min(length, combined.count - cursor)
            if available > 1 {
                for index in 1 ..< available {
                    let byte = combined[cursor + index]
                    metrics.scannerBytes = ParseWorkMetrics.saturatingAdd(metrics.scannerBytes, 1)
                    guard byte & 0xC0 == 0x80 else { throw BufferError.invalidUTF8 }
                    if index == 1 {
                        if first == 0xE0, byte < 0xA0 { throw BufferError.invalidUTF8 }
                        if first == 0xED, byte >= 0xA0 { throw BufferError.invalidUTF8 }
                        if first == 0xF0, byte < 0x90 { throw BufferError.invalidUTF8 }
                        if first == 0xF4, byte >= 0x90 { throw BufferError.invalidUTF8 }
                    }
                }
            }
            guard available == length else { break }
            cursor += length
            complete = cursor
        }
        let text = String(decoding: combined[..<complete], as: UTF8.self)
        metrics.materializationBytes = ParseWorkMetrics.saturatingAdd(metrics.materializationBytes, complete)
        var next = self
        next.pending = []
        try next.append(text, metrics: &metrics)
        next.pending = Array(combined[complete...])
        metrics.materializationBytes = ParseWorkMetrics.saturatingAdd(metrics.materializationBytes, next.pending.count)
        self = next
    }

    package func materialize(from start: Int, metrics: inout ParseWorkMetrics, cancellable: Bool = true) throws -> String {
        guard start >= 0, start <= self.utf8Count else { throw BufferError.invalidBoundary }
        if cancellable { try Task.checkCancellation() }
        guard let root, start < root.count else { return "" }
        if let terminal, start == root.count - terminal.count, let text = terminal.text {
            metrics.recordMetadata(MemoryLayout<String>.stride)
            return text
        }
        var candidate = root
        var localStart = start
        while let left = candidate.left, let right = candidate.right {
            metrics.recordMetadata(MemoryLayout<Node>.stride + MemoryLayout<Int>.stride)
            if localStart < left.count { candidate = left }
            else { localStart -= left.count; candidate = right }
        }
        if localStart == 0, candidate.count == root.count - start, let text = candidate.text {
            metrics.recordMetadata(MemoryLayout<String>.stride)
            return text
        }
        var output = ""
        output.reserveCapacity(root.count - start)
        var stack: [(Node, Int)] = [(root, 0)]
        while let (node, offset) = stack.popLast() {
            if cancellable { try Task.checkCancellation() }
            guard offset + node.count > start else { continue }
            if let text = node.text {
                let local = max(0, start - offset)
                let byteIndex = text.utf8.index(text.utf8.startIndex, offsetBy: local)
                // A scalar boundary can lie inside a grapheme (combining marks,
                // ZWJ emoji, CRLF). UTF8 decoding is deliberately scalar-based.
                guard byteIndex == text.utf8.endIndex || text.utf8[byteIndex] & 0xC0 != 0x80 else {
                    throw BufferError.invalidBoundary
                }
                if local == 0 {
                    output.append(text)
                    metrics.materializationBytes = ParseWorkMetrics.saturatingAdd(metrics.materializationBytes, node.count)
                } else {
                    let suffix = String(decoding: text.utf8[byteIndex...], as: UTF8.self)
                    output.append(suffix)
                    metrics.materializationBytes = ParseWorkMetrics.saturatingAdd(metrics.materializationBytes, 2 * (node.count - local))
                }
            } else if let left = node.left, let right = node.right {
                stack.append((right, offset + left.count))
                if offset + left.count > start { stack.append((left, offset)) }
            }
        }
        return output
    }

    private static func branch(_ left: Node, _ right: Node, metrics: inout ParseWorkMetrics) -> Node {
        metrics.recordMetadata(2 * MemoryLayout<Node?>.stride + MemoryLayout<String?>.stride + 2 * MemoryLayout<Int>.stride)
        return Node(left: left, right: right)
    }

    private static func join(_ left: Node?, _ right: Node, metrics: inout ParseWorkMetrics) -> Node {
        guard let left else { return right }
        if left.height > right.height + 1, let ll = left.left, let lr = left.right {
            let newRight = self.join(lr, right, metrics: &metrics)
            if newRight.height > ll.height + 1, let rl = newRight.left, let rr = newRight.right {
                return self.branch(self.branch(ll, rl, metrics: &metrics), rr, metrics: &metrics)
            }
            return self.branch(ll, newRight, metrics: &metrics)
        }
        return self.branch(left, right, metrics: &metrics)
    }
}

/// A persistent binary forest of balanced block trees. Appending merges equal
/// heights like a binary counter, amortizing metadata allocation. The forest
/// spine and each tree have logarithmic depth; all enumeration is iterative.
package struct PersistentValues<Element: Sendable>: Sequence {
    fileprivate final class Node: Sendable {
        let values: ArraySlice<Element>
        let left: Node?
        let right: Node?
        let count: Int
        let height: Int
        init(_ values: ArraySlice<Element>) {
            self.values = values; self.left = nil; self.right = nil
            self.count = values.count; self.height = 1
        }

        init(_ left: Node, _ right: Node) {
            self.values = []; self.left = left; self.right = right
            self.count = left.count + right.count
            self.height = 1 + Swift.max(left.height, right.height)
        }
    }

    fileprivate final class Segment: Sendable {
        let tree: Node
        let earlier: Segment?
        let count: Int
        init(_ tree: Node, earlier: Segment?) {
            self.tree = tree; self.earlier = earlier
            self.count = tree.count + (earlier?.count ?? 0)
        }
    }

    private let root: Segment?
    package var count: Int {
        self.root?.count ?? 0
    }

    package var depth: Int {
        var depth = 0
        var segment = self.root
        while let current = segment {
            depth = Swift.max(depth, current.tree.height); segment = current.earlier
        }
        return depth
    }

    package var isEmpty: Bool {
        self.root == nil
    }

    package init(_ values: [Element] = []) {
        self.root = values.isEmpty ? nil : Segment(Node(values[...]), earlier: nil)
    }

    private init(_ root: Segment?) {
        self.root = root
    }

    package subscript(_ index: Int) -> Element {
        precondition(index >= 0 && index < self.count)
        var segment = self.root!
        while let earlier = segment.earlier, index < earlier.count {
            segment = earlier
        }
        var cursor = segment.tree
        var index = index - (segment.earlier?.count ?? 0)
        while let left = cursor.left, let right = cursor.right {
            if index < left.count { cursor = left }
            else { index -= left.count; cursor = right }
        }
        return cursor.values[cursor.values.startIndex + index]
    }

    package struct Iterator: IteratorProtocol {
        private var stack: [Node]
        private var values: ArraySlice<Element> = []
        package private(set) var metadataBytes = 0
        fileprivate init(_ root: Segment?) {
            self.stack = []
            var segment = root
            while let current = segment {
                self.stack.append(current.tree)
                self.metadataBytes += MemoryLayout<Node>.stride
                segment = current.earlier
            }
        }

        package mutating func next() -> Element? {
            while self.values.isEmpty {
                guard let node = self.stack.popLast() else { return nil }
                if let left = node.left, let right = node.right {
                    self.stack.append(right); self.stack.append(left)
                    self.metadataBytes = ParseWorkMetrics.saturatingAdd(self.metadataBytes, 2 * MemoryLayout<Node>.stride)
                } else { self.values = node.values }
            }
            return self.values.popFirst()
        }
    }

    package func makeIterator() -> Iterator {
        Iterator(self.root)
    }

    package func materializedMap<T>(_ transform: (Element) -> T, metrics: inout ParseWorkMetrics) -> [T] {
        var iterator = self.makeIterator()
        var output: [T] = []
        output.reserveCapacity(self.count)
        while let element = iterator.next() {
            output.append(transform(element))
        }
        metrics.recordMetadata(iterator.metadataBytes + output.count * MemoryLayout<T>.stride)
        return output
    }

    package func materializedFlatMap<T>(_ transform: (Element) -> [T], metrics: inout ParseWorkMetrics) -> [T] {
        var iterator = self.makeIterator()
        var output: [T] = []
        while let element = iterator.next() {
            let values = transform(element)
            metrics.recordArrayGrowth(output, adding: values.count)
            output.append(contentsOf: values)
        }
        metrics.recordMetadata(iterator.metadataBytes + output.count * MemoryLayout<T>.stride)
        return output
    }

    package func slice(_ range: Range<Int>, metrics: inout ParseWorkMetrics) -> Self {
        precondition(range.lowerBound >= 0 && range.upperBound <= self.count)
        if range == 0 ..< self.count { return self }
        guard !range.isEmpty else { return Self() }
        var trees: [Node] = []
        var segment = self.root
        while let current = segment {
            let offset = current.earlier?.count ?? 0
            if offset < range.upperBound, current.count > range.lowerBound,
               let tree = Self.slice(current.tree, Swift.max(0, range.lowerBound - offset) ..< Swift.min(current.tree.count, range.upperBound - offset), metrics: &metrics) {
                trees.append(tree)
                metrics.recordMetadata(MemoryLayout<Node>.stride)
            }
            segment = current.earlier
        }
        var result: Segment?
        for tree in trees.reversed() {
            result = Self.append(tree, to: result, metrics: &metrics)
        }
        return Self(result)
    }

    package func appending(_ other: Self, metrics: inout ParseWorkMetrics) -> Self {
        guard other.root != nil else { return self }
        guard self.root != nil else { return other }
        var trees: [Node] = []
        var segment = other.root
        while let current = segment {
            trees.append(current.tree)
            metrics.recordMetadata(MemoryLayout<Node>.stride)
            segment = current.earlier
        }
        var result = self.root
        for tree in trees.reversed() {
            result = Self.append(tree, to: result, metrics: &metrics)
        }
        return Self(result)
    }

    private static func append(_ tree: Node, to root: Segment?, metrics: inout ParseWorkMetrics) -> Segment {
        var tree = tree
        var earlier = root
        while let current = earlier, current.tree.height <= tree.height {
            tree = Self.join(current.tree, tree, metrics: &metrics)!
            earlier = current.earlier
        }
        metrics.recordMetadata(2 * MemoryLayout<Node>.stride + MemoryLayout<Int>.stride)
        return Segment(tree, earlier: earlier)
    }

    private static func slice(_ node: Node?, _ range: Range<Int>, metrics: inout ParseWorkMetrics) -> Node? {
        guard let node, !range.isEmpty else { return nil }
        if range == 0 ..< node.count { return node }
        if let left = node.left, let right = node.right {
            if range.upperBound <= left.count { return self.slice(left, range, metrics: &metrics) }
            if range.lowerBound >= left.count {
                return self.slice(right, range.lowerBound - left.count ..< range.upperBound - left.count, metrics: &metrics)
            }
            return self.join(
                self.slice(left, range.lowerBound ..< left.count, metrics: &metrics),
                self.slice(right, 0 ..< range.upperBound - left.count, metrics: &metrics), metrics: &metrics
            )
        }
        metrics.recordMetadata(64)
        let start = node.values.startIndex
        return Node(node.values[start + range.lowerBound ..< start + range.upperBound])
    }

    private static func branch(_ left: Node, _ right: Node, metrics: inout ParseWorkMetrics) -> Node {
        metrics.recordMetadata(64)
        return Node(left, right)
    }

    private static func join(_ left: Node?, _ right: Node?, metrics: inout ParseWorkMetrics) -> Node? {
        guard let left else { return right }
        guard let right else { return left }
        if left.height > right.height + 1, let ll = left.left, let lr = left.right {
            return self.balance(ll, self.join(lr, right, metrics: &metrics)!, metrics: &metrics)
        }
        if right.height > left.height + 1, let rl = right.left, let rr = right.right {
            return self.balance(self.join(left, rl, metrics: &metrics)!, rr, metrics: &metrics)
        }
        return self.branch(left, right, metrics: &metrics)
    }

    private static func balance(_ left: Node, _ right: Node, metrics: inout ParseWorkMetrics) -> Node {
        if left.height > right.height + 1, let ll = left.left, let lr = left.right {
            if lr.height > ll.height, let lrl = lr.left, let lrr = lr.right {
                return self.branch(self.branch(ll, lrl, metrics: &metrics), self.branch(lrr, right, metrics: &metrics), metrics: &metrics)
            }
            return self.branch(ll, self.branch(lr, right, metrics: &metrics), metrics: &metrics)
        }
        if right.height > left.height + 1, let rl = right.left, let rr = right.right {
            if rl.height > rr.height, let rll = rl.left, let rlr = rl.right {
                return self.branch(self.branch(left, rll, metrics: &metrics), self.branch(rlr, rr, metrics: &metrics), metrics: &metrics)
            }
            return self.branch(self.branch(left, rl, metrics: &metrics), rr, metrics: &metrics)
        }
        return self.branch(left, right, metrics: &metrics)
    }
}

extension PersistentValues: Equatable where Element: Equatable {
    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.root === rhs.root || (lhs.count == rhs.count && lhs.elementsEqual(rhs))
    }
}
