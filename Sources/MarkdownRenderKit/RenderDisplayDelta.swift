import MarkdownCore

/// A block-aligned replacement. Unchanged prefix/suffix values remain in the
/// previous model and are structurally shared when the delta is applied.
package struct RenderDisplayDelta: Equatable {
    package let replacedPreviousBlocks: Range<Int>
    package let changedDocumentBlocks: Range<Int>
    package let replacementStorage: PersistentValues<DisplayBlockBundle>
    package let removedResourceIDs: Set<ResourceID>
    package let input: RenderInput
    package init(
        replacedPreviousBlocks: Range<Int>,
        changedDocumentBlocks: Range<Int>,
        replacementStorage: PersistentValues<DisplayBlockBundle>,
        removedResourceIDs: Set<ResourceID>,
        input: RenderInput
    ) {
        self.replacedPreviousBlocks = replacedPreviousBlocks; self.changedDocumentBlocks = changedDocumentBlocks
        self.replacementStorage = replacementStorage; self.removedResourceIDs = removedResourceIDs; self.input = input
    }

    package var replacementBlocks: [DisplayBlock] {
        var metrics = ParseWorkMetrics()
        let result = self.replacementStorage.materializedMap(\.block, metrics: &metrics)
        self.input.document.workRecorder?.recordFacade(metrics)
        return result
    }

    package var replacementRuns: [DisplayRun] {
        self.observeFlatMap { $0.block.runs }
    }

    package var replacementResources: [UnresolvedResource] {
        self.observeFlatMap(\.resources)
    }

    package var replacementAccessibilityRoots: [AccessibilityNode] {
        self.observeFlatMap(\.accessibilityRoots)
    }

    private func observeFlatMap<T>(_ transform: (DisplayBlockBundle) -> [T]) -> [T] {
        var metrics = ParseWorkMetrics()
        let result = self.replacementStorage.materializedFlatMap(transform, metrics: &metrics)
        self.input.document.workRecorder?.recordFacade(metrics)
        return result
    }

    package func preparingSyntax(metrics: inout ParseWorkMetrics) async throws -> Self {
        try await Self(
            replacedPreviousBlocks: self.replacedPreviousBlocks,
            changedDocumentBlocks: self.changedDocumentBlocks,
            replacementStorage: RenderDisplayModel.prepareSyntax(self.replacementStorage, metrics: &metrics),
            removedResourceIDs: self.removedResourceIDs,
            input: self.input
        )
    }

    package func applying(to previous: RenderDisplayModel) -> RenderDisplayModel {
        var metrics = ParseWorkMetrics()
        return self.applying(to: previous, metrics: &metrics)
    }

    package func applying(to previous: RenderDisplayModel, metrics: inout ParseWorkMetrics) -> RenderDisplayModel {
        let prefix = previous.bundles.slice(0 ..< self.replacedPreviousBlocks.lowerBound, metrics: &metrics)
        let suffix = previous.bundles.slice(self.replacedPreviousBlocks.upperBound ..< previous.bundles.count, metrics: &metrics)
        var model = RenderDisplayModel(
            bundles: prefix.appending(self.replacementStorage, metrics: &metrics).appending(suffix, metrics: &metrics), input: self.input
        )
        model.materializationDelta = MaterializationDelta(baselineModelID: previous.identity, replacedBlocks: self.replacedPreviousBlocks, changedBlocks: self.changedDocumentBlocks)
        return model
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.replacedPreviousBlocks == rhs.replacedPreviousBlocks && lhs.changedDocumentBlocks == rhs.changedDocumentBlocks
            && lhs.replacementStorage == rhs.replacementStorage && lhs.removedResourceIDs == rhs.removedResourceIDs
    }
}

extension RenderPreparer {
    package func prepareDelta(
        _ input: RenderInput, replacing previousBlocks: Range<Int>, with changedBlocks: Range<Int>,
        metrics: inout ParseWorkMetrics
    ) throws -> RenderDisplayDelta {
        let replacement = try self.prepareBlocks(input, range: changedBlocks, metrics: &metrics)
        var removed: Set<ResourceID> = []
        if let previous = input.previousModel {
            for index in previousBlocks {
                try Task.checkCancellation()
                for resource in previous.bundles[index].resources {
                    try Task.checkCancellation()
                    metrics.materializationBytes = ParseWorkMetrics.saturatingAdd(metrics.materializationBytes, resource.id.rawValue.utf8.count)
                    removed.insert(resource.id)
                    metrics.recordMetadata(MemoryLayout<ResourceID>.stride)
                }
            }
        }
        for bundle in replacement {
            try Task.checkCancellation()
            for resource in bundle.resources {
                try Task.checkCancellation()
                metrics.materializationBytes = ParseWorkMetrics.saturatingAdd(metrics.materializationBytes, resource.id.rawValue.utf8.count)
                removed.remove(resource.id)
            }
        }
        return RenderDisplayDelta(
            replacedPreviousBlocks: previousBlocks,
            changedDocumentBlocks: changedBlocks,
            replacementStorage: replacement,
            removedResourceIDs: removed,
            input: input
        )
    }
}

extension UnresolvedResource {
    package var id: ResourceID {
        switch self {
        case .image(let id, _, _), .math(let id, _, _), .svg(let id, _): id
        }
    }
}
