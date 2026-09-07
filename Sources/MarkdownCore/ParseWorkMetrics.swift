import Synchronization

/// Package-only checkpoint seam. Production checks real cooperative cancellation;
/// deterministic tests cancel their current task at a chosen checkpoint.
package typealias ParseCancellationCheck = @Sendable () throws -> Void

package enum ParseWorkPhase {
    case scanner, mapping, materialization, cmark, preparation, metadata, syntaxBlocks, facades
}

/// One attempt's monotonic work log. It never owns source/model backing or
/// participates in cancellation/publication decisions. Snapshots have no recorder.
package final class ParseAttemptRecorder: Sendable {
    private let state = Mutex(ParseWorkMetrics())
    package init() {}
    package func record(_ value: ParseWorkMetrics) {
        self.state.withLock { $0.add(value.withoutRecording) }
    }

    package func record(_ phase: ParseWorkPhase, bytes: Int) {
        self.state.withLock { metrics in
            switch phase {
            case .scanner: metrics.scannerBytes = ParseWorkMetrics.saturatingAdd(metrics.scannerBytes, bytes)
            case .mapping: metrics.mappingBytes = ParseWorkMetrics.saturatingAdd(metrics.mappingBytes, bytes)
            case .materialization: metrics.materializationBytes = ParseWorkMetrics.saturatingAdd(metrics.materializationBytes, bytes)
            case .cmark: metrics.cmarkInputBytes = ParseWorkMetrics.saturatingAdd(metrics.cmarkInputBytes, bytes)
            case .preparation: metrics.renderPreparationBytes = ParseWorkMetrics.saturatingAdd(metrics.renderPreparationBytes, bytes)
            case .metadata: metrics.metadataBytes = ParseWorkMetrics.saturatingAdd(metrics.metadataBytes, bytes)
            case .syntaxBlocks: metrics.syntaxPreparationBlocks = ParseWorkMetrics.saturatingAdd(metrics.syntaxPreparationBlocks, bytes)
            case .facades: metrics.facadeMaterializationCount = ParseWorkMetrics.saturatingAdd(metrics.facadeMaterializationCount, bytes)
            }
        }
    }

    package func snapshot() -> ParseWorkMetrics {
        self.state.withLock { $0 }
    }
}

/// Deterministic bytes visited or copied by the parse/preparation pipeline.
/// Platform attributed-string assembly and layout are measured separately.
package struct ParseWorkMetrics: Equatable {
    package var scannerBytes = 0 {
        didSet { self.record(self.scannerBytes, previous: oldValue, phase: .scanner) }
    }

    package var mappingBytes = 0 {
        didSet { self.record(self.mappingBytes, previous: oldValue, phase: .mapping) }
    }

    package var materializationBytes = 0 {
        didSet { self.record(self.materializationBytes, previous: oldValue, phase: .materialization) }
    }

    package var cmarkInputBytes = 0 {
        didSet { self.record(self.cmarkInputBytes, previous: oldValue, phase: .cmark) }
    }

    package var renderPreparationBytes = 0 {
        didSet { self.record(self.renderPreparationBytes, previous: oldValue, phase: .preparation) }
    }

    /// Fixed-size semantic/structural records, separate from source-payload gates.
    package var metadataBytes = 0 {
        didSet { self.record(self.metadataBytes, previous: oldValue, phase: .metadata) }
    }

    /// Diagnostic proof that production syntax preparation visits only delta blocks.
    package var syntaxPreparationBlocks = 0 {
        didSet { self.record(self.syntaxPreparationBlocks, previous: oldValue, phase: .syntaxBlocks) }
    }

    package var facadeMaterializationCount = 0 {
        didSet { self.record(self.facadeMaterializationCount, previous: oldValue, phase: .facades) }
    }

    package var total: Int {
        [self.scannerBytes, self.mappingBytes, self.materializationBytes, self.cmarkInputBytes, self.renderPreparationBytes]
            .reduce(0, Self.saturatingAdd)
    }

    package private(set) var recorder: ParseAttemptRecorder?
    package init(recording recorder: ParseAttemptRecorder? = nil) {
        self.recorder = recorder
    }

    private func record(_ value: Int, previous: Int, phase: ParseWorkPhase) {
        if value > previous { self.recorder?.record(phase, bytes: value - previous) }
    }

    package var withoutRecording: Self {
        var copy = self; copy.recorder = nil; return copy
    }

    package func recording(_ recorder: ParseAttemptRecorder, seed: Bool = false) -> Self {
        var copy = self; copy.recorder = recorder
        if seed { recorder.record(self.withoutRecording) }
        return copy
    }

    /// Aggregate values already recorded by a child phase without counting them twice.
    package mutating func addRecorded(_ other: Self) {
        let recorder = self.recorder; self.recorder = nil
        self.add(other)
        self.recorder = recorder
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        [lhs.scannerBytes, lhs.mappingBytes, lhs.materializationBytes, lhs.cmarkInputBytes, lhs.renderPreparationBytes, lhs.metadataBytes, lhs.syntaxPreparationBlocks, lhs.facadeMaterializationCount] == [rhs.scannerBytes, rhs.mappingBytes, rhs.materializationBytes, rhs.cmarkInputBytes, rhs.renderPreparationBytes, rhs.metadataBytes, rhs.syntaxPreparationBlocks, rhs.facadeMaterializationCount]
    }

    package mutating func add(_ other: Self) {
        self.scannerBytes = Self.saturatingAdd(self.scannerBytes, other.scannerBytes)
        self.mappingBytes = Self.saturatingAdd(self.mappingBytes, other.mappingBytes)
        self.materializationBytes = Self.saturatingAdd(self.materializationBytes, other.materializationBytes)
        self.cmarkInputBytes = Self.saturatingAdd(self.cmarkInputBytes, other.cmarkInputBytes)
        self.renderPreparationBytes = Self.saturatingAdd(self.renderPreparationBytes, other.renderPreparationBytes)
        self.metadataBytes = Self.saturatingAdd(self.metadataBytes, other.metadataBytes)
        self.syntaxPreparationBlocks = Self.saturatingAdd(self.syntaxPreparationBlocks, other.syntaxPreparationBlocks)
        self.facadeMaterializationCount = Self.saturatingAdd(self.facadeMaterializationCount, other.facadeMaterializationCount)
    }

    package mutating func recordMetadata(_ bytes: Int) {
        self.metadataBytes = Self.saturatingAdd(self.metadataBytes, bytes)
    }

    package mutating func recordPreparationMetadata(_ bytes: Int) {
        self.metadataBytes = Self.saturatingAdd(self.metadataBytes, bytes)
    }

    package static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    package static func saturatingMultiply(_ lhs: Int, _ rhs: Int) -> Int {
        let (product, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? Int.max : product
    }

    /// Use immediately before growth of a worker-local, non-aliased array.
    /// Counts relocation of initialized elements; unused capacity is not payload.
    package mutating func recordArrayGrowth<T>(_ values: borrowing [T], adding: Int = 1, preparation: Bool = false) {
        guard adding > values.capacity - values.count else { return }
        let bytes = Self.saturatingMultiply(values.count, MemoryLayout<T>.stride)
        if preparation { self.recordPreparationMetadata(bytes) }
        else { self.recordMetadata(bytes) }
    }
}

/// Operation/session-scoped observation only. It never owns or controls backing
/// data, parsing, cancellation, or publication. Snapshot/drain are linearizable.
package final class ParseWorkRecorder: Sendable {
    private struct State { var total = ParseWorkMetrics(); var pending = ParseWorkMetrics() }
    private let state = Mutex(State())
    private let parent: ParseWorkRecorder?
    private let attempt: ParseAttemptRecorder?
    package init(parent: ParseWorkRecorder? = nil, attempt: ParseAttemptRecorder? = nil) {
        self.parent = parent; self.attempt = attempt
    }

    package func recordFacade(_ value: ParseWorkMetrics) {
        var value = value.withoutRecording
        value.facadeMaterializationCount = ParseWorkMetrics.saturatingAdd(value.facadeMaterializationCount, 1)
        self.record(value)
    }

    private func record(_ value: ParseWorkMetrics) {
        self.state.withLock { $0.total.add(value); $0.pending.add(value) }
        self.attempt?.record(value)
        self.parent?.record(value)
    }

    package func snapshot() -> ParseWorkMetrics {
        self.state.withLock { $0.total }
    }

    package func drain() -> ParseWorkMetrics {
        self.state.withLock { state in
            let pending = state.pending
            state.pending = ParseWorkMetrics()
            return pending
        }
    }
}

/// Worker-local instrumentation; never stored in a document or shared across
/// actors. Opaque primitives are charged their input/output bytes at the call.
package final class ParseWorkAccumulator {
    package var metrics: ParseWorkMetrics
    private let cancellable: Bool
    private let checkCancellation: ParseCancellationCheck
    private var workUntilCheck = 0
    package var decodedEventCount = 0
    package init(_ metrics: ParseWorkMetrics = .init(), cancellable: Bool, checkCancellation: @escaping ParseCancellationCheck = { try Task.checkCancellation() }) {
        self.metrics = metrics
        self.cancellable = cancellable
        self.checkCancellation = checkCancellation
    }

    package func check() throws {
        if self.cancellable { try self.checkCancellation() }
    }

    private func checkpoint(_ count: Int) throws {
        if count >= 1024 || self.workUntilCheck >= 1024 - count {
            self.workUntilCheck = 0
            try self.check()
        } else { self.workUntilCheck += count }
    }

    package func scan(_ count: Int = 1) throws {
        self.metrics.scannerBytes = ParseWorkMetrics.saturatingAdd(self.metrics.scannerBytes, count)
        try self.checkpoint(count)
    }

    package func map(_ count: Int = 1) throws {
        self.metrics.mappingBytes = ParseWorkMetrics.saturatingAdd(self.metrics.mappingBytes, count)
        try self.checkpoint(count)
    }

    package func copy(_ count: Int) throws {
        self.metrics.materializationBytes = ParseWorkMetrics.saturatingAdd(self.metrics.materializationBytes, count)
        try self.checkpoint(count)
    }

    package func metadata(_ count: Int) throws {
        self.metrics.recordMetadata(count)
        try self.checkpoint(count)
    }

    package func arrayGrowth(_ values: borrowing [some Any], adding: Int = 1) throws {
        self.metrics.recordArrayGrowth(values, adding: adding)
        try self.checkpoint(1)
    }
}
