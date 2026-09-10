import Darwin
import Foundation
@testable import MarkdownPlatformView
@testable import MarkdownRenderKit
import OhMyMarkdown
import Testing

/// Never resumes on its own, so every started transfer keeps its permit and its
/// full encoded reservation until the test releases it.
actor HeldImageLoader: MarkdownImageLoading {
    private var pending: [CheckedContinuation<MarkdownImagePayload, any Error>] = []
    private(set) var starts = 0
    func load(_ request: MarkdownImageRequest) async throws -> MarkdownImagePayload {
        self.starts += 1
        return try await withCheckedThrowingContinuation { self.pending.append($0) }
    }

    func rejectAll() {
        let waiting = self.pending
        self.pending.removeAll()
        for continuation in waiting {
            continuation.resume(throwing: MarkdownResourceError.transport)
        }
    }
}

actor FixtureImageLoader: MarkdownImageLoading {
    private let data: Data
    private let mime: String
    private(set) var calls = 0
    init(data: Data, mime: String = "image/png") {
        self.data = data
        self.mime = mime
    }

    func load(_ request: MarkdownImageRequest) async throws -> MarkdownImagePayload {
        self.calls += 1
        return MarkdownImagePayload(data: self.data, declaredMIMEType: self.mime)
    }
}

actor PausedFixtureLoader: MarkdownImageLoading {
    private var pending: [CheckedContinuation<MarkdownImagePayload, any Error>] = []
    private(set) var calls = 0
    func load(_ request: MarkdownImageRequest) async throws -> MarkdownImagePayload {
        self.calls += 1
        return try await withCheckedThrowingContinuation { self.pending.append($0) }
    }

    /// Never silently drops: a no-op here would read as a passing test.
    func finish(_ result: Result<MarkdownImagePayload, any Error>) {
        guard !self.pending.isEmpty else {
            Issue.record("No pending image request to complete")
            return
        }
        self.pending.removeFirst().resume(with: result)
    }
}

/// Diagnostic only. Allocator and framework overhead are not decoded pixels, so
/// this number is never compared against the ledger's accounted bytes.
private func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.resident_size : 0
}

@MainActor
final class VanishingSink: RenderSessionSink {
    func replaceSnapshot(_ snapshot: RenderSnapshot, token: RenderCommitToken) {
        Issue.record("Disappeared sink installed a snapshot")
    }

    func receive(error: RenderSessionError) {
        Issue.record("Disappeared sink received an error")
    }
}

@MainActor
@Suite(.serialized)
struct ImageAdversarialTests {
    private func views(
        _ residency: ImageResidencyConfiguration, clock: ManualRenderClock, executor: ParseExecutor,
        sessions: Int = 5, perSession: Int = 20,
        configuration: (Int) -> MarkdownImageConfiguration
    ) -> [MarkdownLabelView] {
        (0 ..< sessions).map { session in
            let view = imageTestView(
                frame: CGRect(x: 0, y: 0, width: 320, height: 200), residency: residency,
                clock: clock, executor: executor
            )
            view.remoteImages = configuration(session)
            view.blocks = MarkdownDocument(parsing: (0 ..< perSession).map {
                "![alt \(session)-\($0)](https://images.test/\(session)/\($0).png)"
            }.joined(separator: "\n\n")).blocks
            return view
        }
    }

    @Test func hundredImagesBoundTransfersAndReserveFullBodiesBeforeAnyNetworkStart() async {
        let clock = ManualRenderClock()
        let executor = ParseExecutor()
        let loader = HeldImageLoader()
        let residency = isolatedImageResidency()
        let views = self.views(residency, clock: clock, executor: executor) { _ in MarkdownImageConfiguration(loader: loader) }
        #expect(await settle(clock) { views.allSatisfy { $0.currentSnapshot != nil } })
        // Quiescence is the exact admitted/queued split, not a wall-clock or
        // yield-count guess: four of the hundred requests hold transfer slots and
        // the remaining ninety-six wait without any body reserved.
        #expect(await settle(clock) {
            let statistics = await residency.permits.statistics
            return statistics.transfers == 4 && statistics.transferWaiters == 96
        })
        let held = await residency.permits.statistics
        #expect(await loader.starts == 4)
        #expect(held.transfers == 4)
        #expect(held.peakTransfers == 4)
        #expect(held.encodedBytes == 80 * 1024 * 1024)
        #expect(held.peakEncodedBytes == 80 * 1024 * 1024)
        #expect(held.transferWaiters > 0)
        #expect(residency.ledger.accountedBytes == 0)

        for view in views {
            view.dismantleRenderSession()
        }
        await loader.rejectAll()
        #expect(await settle(clock) { await residency.permits.statistics.isEmpty })
        let final = await residency.permits.statistics
        #expect(final.peakTransfers == 4)
        #expect(final.peakDecodes == 0)
        #expect(residency.ledger.isAtBaseline)
    }

    @Test func hundredImagesDegradeInsteadOfExceedingResidencyAndReturnToBaseline() async throws {
        let clock = ManualRenderClock()
        let executor = ParseExecutor()
        let png = try encodedPNG(width: 40, height: 40)
        let loader = FixtureImageLoader(data: png)
        // 32 px thumbnails cost alignUp(32 * 4, 64) * 32 = 4096 bytes each, so a
        // 24 KiB ledger can hold at most six of the hundred requests at once.
        let residency = isolatedImageResidency(hardLimit: 24 << 10, cacheLimit: 8 << 10, maxPixelSize: 32)
        let before = residentBytes()
        let views = self.views(residency, clock: clock, executor: executor) { _ in MarkdownImageConfiguration(loader: loader) }
        #expect(await settle(clock) { views.allSatisfy { $0.currentSnapshot != nil } })
        // Let all hundred resolutions settle with the coalescing debounce still
        // closed, then flush once: one re-materialization per view instead of one
        // per arriving batch.
        #expect(await quiesce { await loader.calls == 100 })
        // Every resolution has settled: a deterministic signal, not a turn count.
        let settled = { views.reduce(0) { $0 + ($1.imageCoordinator?.settledResolutionCount ?? 0) } }
        #expect(await quiesce { settled() == 100 })
        await flushCoalescedResources(clock)
        #expect(views.allSatisfy { $0.imageRequests.values.allSatisfy { $0 != .loading } })
        let peak = await residency.permits.statistics
        #expect(peak.peakTransfers <= 4)
        #expect(peak.peakDecodes <= 2)
        #expect(peak.peakEncodedBytes <= 80 * 1024 * 1024)
        #expect(residency.ledger.accountedBytes <= 24 << 10)
        #expect(residency.ledger.cacheBytes <= 8 << 10)
        // The completion callback clears the request before the coalesced
        // re-materialization installs the attachment, so publication is observed
        // separately rather than assumed from the request state above.
        #expect(views.contains { !($0.currentSnapshot?.resourceOwners.isEmpty ?? true) })
        #expect(views.contains { $0.imageRequests.values.contains(.deferred) })

        // Evicting cache ownership while attachments still display the backings
        // cannot uncharge them.
        let charged = residency.ledger.accountedBytes
        residency.ledger.handleMemoryPressure()
        #expect(residency.ledger.cacheBytes == 0)
        #expect(residency.ledger.accountedBytes == charged)

        for view in views {
            view.dismantleRenderSession()
        }
        #expect(await settle(clock) { residency.ledger.isAtBaseline })
        #expect(await settle(clock) { await residency.permits.statistics.isEmpty })
        print("task-7 diagnostic: resident bytes \(before) -> \(residentBytes())")
    }

    @Test func defaultWrappersIsolateCompletedCacheButSharedSemanticIDReuses() async throws {
        let clock = ManualRenderClock()
        let executor = ParseExecutor()
        let png = try encodedPNG(width: 16, height: 16)
        let residency = isolatedImageResidency(maxPixelSize: 32)
        let source = "![alt](https://images.test/shared.png)"
        let first = FixtureImageLoader(data: png)
        let second = FixtureImageLoader(data: png)

        let isolatedA = imageTestView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), residency: residency, clock: clock, executor: executor)
        isolatedA.remoteImages = MarkdownImageConfiguration(loader: first)
        isolatedA.blocks = MarkdownDocument(parsing: source).blocks
        #expect(await settle(clock) { isolatedA.currentSnapshot?.resourceOwners.count == 1 })
        let isolatedB = imageTestView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), residency: residency, clock: clock, executor: executor)
        isolatedB.remoteImages = MarkdownImageConfiguration(loader: second)
        isolatedB.blocks = MarkdownDocument(parsing: source).blocks
        #expect(await settle(clock) { isolatedB.currentSnapshot?.resourceOwners.count == 1 })
        #expect(await first.calls == 1)
        #expect(await second.calls == 1)

        let identity = MarkdownConfigurationID.semantic(namespace: "adversarial.images", version: 1)
        let third = FixtureImageLoader(data: png)
        let fourth = FixtureImageLoader(data: png)
        let sharedA = imageTestView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), residency: residency, clock: clock, executor: executor)
        sharedA.remoteImages = MarkdownImageConfiguration(loader: third, configurationID: identity)
        sharedA.blocks = MarkdownDocument(parsing: source).blocks
        #expect(await settle(clock) { sharedA.currentSnapshot?.resourceOwners.count == 1 })
        let sharedB = imageTestView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), residency: residency, clock: clock, executor: executor)
        sharedB.remoteImages = MarkdownImageConfiguration(loader: fourth, configurationID: identity)
        sharedB.blocks = MarkdownDocument(parsing: source).blocks
        #expect(await settle(clock) { sharedB.currentSnapshot?.resourceOwners.count == 1 })
        #expect(await third.calls == 1)
        #expect(await fourth.calls == 0)
        #expect(sharedA.currentSnapshot?.resourceOwners.first as? ImageOwnerLease !== sharedB.currentSnapshot?.resourceOwners.first as? ImageOwnerLease)
        #expect(
            (sharedA.currentSnapshot?.resourceOwners.first as? ImageOwnerLease)?.backingID
                == (sharedB.currentSnapshot?.resourceOwners.first as? ImageOwnerLease)?.backingID
        )

        for view in [isolatedA, isolatedB, sharedA, sharedB] {
            view.dismantleRenderSession()
        }
        residency.ledger.handleMemoryPressure()
        #expect(await settle(clock) { residency.ledger.isAtBaseline })
    }

    @Test func replacedGenerationResultNeverPublishesOrWritesEitherCache() async throws {
        let clock = ManualRenderClock()
        let executor = ParseExecutor()
        let png = try encodedPNG(width: 16, height: 16)
        let loader = PausedFixtureLoader()
        let residency = isolatedImageResidency(maxPixelSize: 32)
        let identity = MarkdownConfigurationID.semantic(namespace: "adversarial.generation", version: 1)
        let view = imageTestView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), residency: residency, clock: clock, executor: executor)
        var failures: [MarkdownResourceFailure] = []
        view.onResourceError = { failures.append($0) }
        view.remoteImages = MarkdownImageConfiguration(loader: loader, configurationID: identity)
        view.blocks = MarkdownDocument(parsing: "![alt](https://images.test/generation.png)").blocks
        #expect(await settle(clock) { await loader.calls == 1 })
        let stale = try #require(view.currentCommitToken)

        view.remoteImages = MarkdownImageConfiguration(loader: loader, configurationID: identity)
        #expect(await settle(clock) { view.currentCommitToken?.configurationGeneration == stale.configurationGeneration + 1 })
        #expect(await settle(clock) { await loader.calls == 2 })

        let images = try #require(view.imageCoordinator)
        #expect(images.settledResolutionCount == 0)
        await loader.finish(.success(MarkdownImagePayload(data: png, declaredMIMEType: "image/png")))
        // The stale resolution has demonstrably run to completion before anything
        // is asserted about it, so "nothing happened" cannot mean "not yet".
        #expect(await settle(clock) { images.settledResolutionCount == 1 })
        #expect(view.currentSnapshot?.resourceOwners.isEmpty == true)
        #expect(residency.ledger.cacheCount == 0)
        #expect(residency.ledger.negativeCount == 0)
        #expect(failures.isEmpty)

        await loader.finish(.success(MarkdownImagePayload(data: png, declaredMIMEType: "image/png")))
        #expect(await settle(clock) { view.currentSnapshot?.resourceOwners.count == 1 })
        #expect(residency.ledger.cacheCount == 1)
        view.dismantleRenderSession()
        residency.ledger.handleMemoryPressure()
        #expect(await settle(clock) { residency.ledger.isAtBaseline })
    }

    @Test func negativeCacheHoldsOnlyDeterministicFailuresAndExpiresOnTheInjectedClock() async throws {
        let clock = ManualRenderClock()
        let executor = ParseExecutor()
        // A separate clock owns the five-minute TTL so driving the session's 33 ms
        // coalescing forward cannot drift the expiry under test.
        let ttlClock = ManualRenderClock()
        let residency = isolatedImageResidency(maxPixelSize: 32, clock: ttlClock)
        let identity = MarkdownConfigurationID.semantic(namespace: "adversarial.negative", version: 1)
        let source = "![alt](https://images.test/negative.png)"

        let deterministic = PausedFixtureLoader()
        let view = imageTestView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), residency: residency, clock: clock, executor: executor)
        var failures: [MarkdownResourceFailure] = []
        view.onResourceError = { failures.append($0) }
        view.remoteImages = MarkdownImageConfiguration(loader: deterministic, configurationID: identity)
        view.blocks = MarkdownDocument(parsing: source).blocks
        #expect(await settle(clock) { await deterministic.calls == 1 })
        try await deterministic.finish(.success(MarkdownImagePayload(data: encodedPNG(width: 8, height: 8), declaredMIMEType: "image/jpeg")))
        #expect(await settle(clock) { failures.count == 1 })
        #expect(failures.first?.category == .typeMismatch)
        #expect(residency.ledger.negativeCount == 1)

        view.blocks = MarkdownDocument(parsing: "prefix\n\n\(source)").blocks
        #expect(await settle(clock) { failures.count == 2 })
        #expect(failures.last?.category == .typeMismatch)
        #expect(await deterministic.calls == 1)

        ttlClock.advance(by: .seconds(299))
        view.blocks = MarkdownDocument(parsing: "second\n\n\(source)").blocks
        #expect(await settle(clock) { failures.count == 3 })
        #expect(await deterministic.calls == 1)
        ttlClock.advance(by: .seconds(2))
        view.blocks = MarkdownDocument(parsing: "third\n\n\(source)").blocks
        #expect(await settle(clock) { await deterministic.calls == 2 })

        // Connectivity failures are reported but never suppress the next attempt.
        await deterministic.finish(.failure(URLError(.timedOut)))
        #expect(await settle(clock) { failures.count == 4 })
        #expect(failures.last?.category == .timedOut)
        // The expired deterministic entry was dropped by the lookup above and the
        // timeout added nothing, so the negative cache is empty.
        #expect(residency.ledger.negativeCount == 0)
        view.blocks = MarkdownDocument(parsing: "fourth\n\n\(source)").blocks
        #expect(await settle(clock) { await deterministic.calls == 3 })
        view.dismantleRenderSession()
        await deterministic.finish(.failure(CancellationError()))
        #expect(await settle(clock) { residency.ledger.isAtBaseline })
    }

    @Test func authorizationGateStopsOldTokenInstallCallbackAndLeaseCommit() throws {
        let clock = ManualRenderClock()
        let executor = ParseExecutor()
        let residency = isolatedImageResidency()
        let registry = RenderSessionSinkRegistry()
        let view = imageTestView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), residency: residency, clock: clock, executor: executor)
        let id = RenderSessionID(rawValue: UUID())
        registry.register(view, for: id)
        let old = RenderCommitToken(sessionID: id, sequence: 1, sourceRevision: 1, configurationGeneration: 1)
        let new = RenderCommitToken(sessionID: id, sequence: 2, sourceRevision: 1, configurationGeneration: 2)
        registry.authorize(old)

        // Prepared before authorization moves on, installed only inside the gate.
        let owned = try ownedTestImage(residency.ledger)
        let backingID = owned.backing.backingID
        let transaction = try #require(residency.ledger.prepareSnapshotReplacement(
            session: id, oldSnapshotID: nil, newSnapshotID: UUID(), images: [owned]
        ))
        #expect(residency.ledger.ownerCount(backingID) == 1)

        registry.authorize(new)
        var installed = false
        let authorized = registry.withAuthorizedSink(for: old) { _ in
            transaction.commit { _, _ in installed = true }
        }
        #expect(!authorized)
        #expect(!installed)
        #expect(transaction.ownerCount == 1)
        transaction.cancel()
        #expect(residency.ledger.ownerCount(backingID) == 0)
        #expect(residency.ledger.isAtBaseline)
        view.dismantleRenderSession()
    }

    @Test func thrownMaterializationAndDisappearingSinkExposeNothing() async throws {
        let clock = ManualRenderClock()
        let executor = ParseExecutor()
        enum Failure: Error { case materialization }
        let png = try encodedPNG(width: 16, height: 16)
        let residency = isolatedImageResidency(maxPixelSize: 32)
        let loader = FixtureImageLoader(data: png)
        let view = imageTestView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), residency: residency, clock: clock, executor: executor)
        view.remoteImages = MarkdownImageConfiguration(loader: loader)
        view.blocks = MarkdownDocument(parsing: "![alt](https://images.test/throwing.png)").blocks
        #expect(await settle(clock) { view.currentSnapshot?.resourceOwners.count == 1 })
        var published = view.currentSnapshot
        let backingID = try #require(published?.resourceOwners.first as? ImageOwnerLease).backingID
        // Session resolution owner, snapshot publication owner, cache owner.
        let owners = residency.ledger.ownerCount(backingID)
        #expect(owners == 3)

        view._materializationFailureForTesting = Failure.materialization
        let model = try #require(published).displayModel
        let token = try #require(view.currentCommitToken)
        view.installSnapshot(model: model, configuration: MarkdownRenderConfiguration.default.snapshot(generation: 0), token: token)
        #expect(view.currentSnapshot === published)
        #expect(view.lastRenderError == .preparationFailed)
        // The attempt acquired a fourth owner and the rollback gave it back; an
        // owner count that stayed at four would fail this.
        #expect(residency.ledger.ownerCount(backingID) == owners)
        view._materializationFailureForTesting = nil

        let registry = RenderSessionSinkRegistry()
        let vanishing = RenderSessionID(rawValue: UUID())
        // A platform view can outlive its own teardown through UIKit/AppKit
        // retention, so the weak-sink contract is proven with a sink whose
        // deallocation the test actually controls.
        var temporary: VanishingSink? = VanishingSink()
        try registry.register(#require(temporary), for: vanishing)
        let vanishingToken = RenderCommitToken(sessionID: vanishing, sequence: 1, sourceRevision: 1, configurationGeneration: 1)
        registry.authorize(vanishingToken)
        weak let observed = temporary
        temporary = nil
        #expect(observed == nil)
        #expect(!registry.withAuthorizedSink(for: vanishingToken) { _ in Issue.record("Disappeared sink installed a snapshot") })

        published = nil
        view.dismantleRenderSession()
        residency.ledger.handleMemoryPressure()
        #expect(await settle(clock) { residency.ledger.isAtBaseline })
    }

    @Test func externallyRetainedOldSnapshotKeepsItsBackingChargedAcrossReplacement() async throws {
        let clock = ManualRenderClock()
        let executor = ParseExecutor()
        let png = try encodedPNG(width: 16, height: 16)
        let residency = isolatedImageResidency(maxPixelSize: 32)
        let loader = FixtureImageLoader(data: png)
        let view = imageTestView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), residency: residency, clock: clock, executor: executor)
        view.remoteImages = MarkdownImageConfiguration(loader: loader)
        view.blocks = MarkdownDocument(parsing: "![alt](https://images.test/retained.png)").blocks
        #expect(await settle(clock) { view.currentSnapshot?.resourceOwners.count == 1 })
        var retained: RenderSnapshot? = view.currentSnapshot
        let backingID = try #require(retained?.resourceOwners.first as? ImageOwnerLease).backingID
        // Session resolution owner, snapshot publication owner and cache owner.
        #expect(residency.ledger.ownerCount(backingID) == 3)

        view.blocks = MarkdownDocument(parsing: "plain text only").blocks
        #expect(await settle(clock) { view.currentSnapshot?.resourceOwners.isEmpty == true })
        // The session released its resolution owner; the retained snapshot and the
        // completed cache still hold the backing charged.
        #expect(residency.ledger.ownerCount(backingID) == 2)
        residency.ledger.handleMemoryPressure()
        #expect(residency.ledger.ownerCount(backingID) == 1)
        #expect(residency.ledger.accountedBytes > 0)
        retained = nil
        #expect(residency.ledger.ownerCount(backingID) == 0)
        #expect(residency.ledger.isAtBaseline)
        view.dismantleRenderSession()
    }

    /// Plan gate 2: pause *inside* replacement, between the lease commit and the
    /// snapshot install, and prove the outgoing backing is still alive and charged.
    @Test func replacementGateKeepsTheOldBackingChargedUntilTextKitIsReplaced() async throws {
        let clock = ManualRenderClock()
        let executor = ParseExecutor()
        let png = try encodedPNG(width: 16, height: 16)
        let residency = isolatedImageResidency(maxPixelSize: 32)
        let loader = FixtureImageLoader(data: png)
        let view = imageTestView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), residency: residency, clock: clock, executor: executor)
        view.remoteImages = MarkdownImageConfiguration(loader: loader)
        view.blocks = MarkdownDocument(parsing: "![alt](https://images.test/gate.png)").blocks
        #expect(await settle(clock) { view.currentSnapshot?.resourceOwners.count == 1 })
        var old = view.currentSnapshot
        let backingID = try #require(old?.resourceOwners.first as? ImageOwnerLease).backingID
        #expect(residency.ledger.ownerCount(backingID) == 3)

        let token = try #require(view.currentCommitToken)
        let configuration = MarkdownRenderConfiguration.default.snapshot(generation: 0)
        let newSnapshotID = UUID()
        var resources: ResolvedResourceSnapshot? = try view.resolvedResources(
            for: #require(old).displayModel, configuration: configuration
        )
        let transaction = try residency.ledger.prepareSnapshotReplacement(
            session: .init(rawValue: UUID()), oldSnapshotID: #require(old).id, newSnapshotID: newSnapshotID,
            owners: #require(resources).owners
        )
        var installedAtGate: UUID?
        var ownersAtGate = 0
        var chargedAtGate = 0
        transaction.commit { handOver, _ in
            // Gate: new owners are committed, nothing is installed yet.
            installedAtGate = view.currentSnapshot?.id
            ownersAtGate = residency.ledger.ownerCount(backingID)
            chargedAtGate = residency.ledger.accountedBytes
            let replacement = RenderMaterializer(configuration: configuration)
                .materialize(old!.displayModel, resources: resources!, snapshotID: newSnapshotID)
            handOver(replacement.resourceOwners)
            view.replaceSnapshot(replacement, token: token)
        }
        #expect(installedAtGate == old?.id)
        #expect(ownersAtGate == 4)
        #expect(chargedAtGate > 0)
        #expect(view.currentSnapshot?.id == newSnapshotID)
        // The outgoing snapshot released its own owner only after TextKit content
        // was replaced; this test still holds `old`, so its charge survives.
        #expect(residency.ledger.ownerCount(backingID) == 4)
        old = nil
        resources = nil
        // Only the replacement snapshot and the session/cache owners remain.
        #expect(residency.ledger.ownerCount(backingID) == 3)
        view.dismantleRenderSession()
        residency.ledger.handleMemoryPressure()
        #expect(await settle(clock) { residency.ledger.isAtBaseline })
    }

    @Test func residencyDeferralHoldsThePlaceholderUntilTheNextCommitToken() async throws {
        let clock = ManualRenderClock()
        let executor = ParseExecutor()
        let png = try encodedPNG(width: 40, height: 40)
        let loader = FixtureImageLoader(data: png)
        // One 32 px thumbnail costs 4096 bytes, so exactly one of the two fits.
        let residency = isolatedImageResidency(hardLimit: 4096, cacheLimit: 4096, maxPixelSize: 32)
        let view = imageTestView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), residency: residency, clock: clock, executor: executor)
        var failures: [MarkdownResourceFailure] = []
        view.onResourceError = { failures.append($0) }
        view.remoteImages = MarkdownImageConfiguration(loader: loader)
        view.blocks = MarkdownDocument(parsing: """
        ![a](https://images.test/defer/a.png)

        ![b](https://images.test/defer/b.png)
        """).blocks
        #expect(await settle(clock) { (view.imageCoordinator?.settledResolutionCount ?? 0) == 2 })
        #expect(await loader.calls == 2)
        #expect(view.imageRequests.values.contains(.deferred))
        // Deferral is not a failure: no negative-cache entry and no host callback.
        #expect(residency.ledger.negativeCount == 0)
        #expect(failures.isEmpty)

        // Within this commit token the placeholder is terminal — no retry storm.
        #expect(await settle(clock) { view.currentSnapshot?.resourceOwners.count == 1 })
        #expect(await loader.calls == 2)
        #expect(view.imageRequests.values.contains(.deferred))

        // A new commit token retries it; residency is still full, so it defers again
        // rather than exceeding the limit.
        view.blocks = MarkdownDocument(parsing: """
        changed

        ![a](https://images.test/defer/a.png)

        ![b](https://images.test/defer/b.png)
        """).blocks
        #expect(await settle(clock) { await loader.calls > 2 })
        #expect(residency.ledger.accountedBytes <= 4096)
        view.dismantleRenderSession()
        residency.ledger.handleMemoryPressure()
        #expect(await settle(clock) { residency.ledger.isAtBaseline })
    }

    /// The hundred-image suites deliberately let every resolution land inside one
    /// debounce window so they stay cheap. That hides the schedule production
    /// actually sees: with at most four transfers and two decodes, arrivals are
    /// spaced wider than the 33 ms window, so each one costs a full
    /// re-materialization of the whole display model. This pins that cost instead
    /// of letting the cheap schedule stand in for it.
    @Test func eachArrivalBatchCostsOneFullRematerialization() async throws {
        let clock = ManualRenderClock()
        let executor = ParseExecutor()
        let png = try encodedPNG(width: 16, height: 16)
        let loader = PausedFixtureLoader()
        let residency = isolatedImageResidency(maxPixelSize: 32)
        let view = imageTestView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 200), residency: residency,
            clock: clock, executor: executor
        )
        view.remoteImages = MarkdownImageConfiguration(loader: loader)
        view.blocks = MarkdownDocument(parsing: (0 ..< 4).map {
            "![alt \($0)](https://images.test/batch/\($0).png)"
        }.joined(separator: "\n\n")).blocks
        #expect(await settle(clock) { view.currentSnapshot != nil })
        let baseline = view._materializationCount
        for index in 0 ..< 4 {
            // Only two transfers run per session, so wait until this arrival's
            // request has actually started before completing it.
            #expect(await settle(clock) { await loader.calls > index })
            let before = view._materializationCount
            await loader.finish(.success(MarkdownImagePayload(data: png, declaredMIMEType: "image/png")))
            #expect(await settle(clock) { view._materializationCount > before })
            // One arrival, one full re-materialization of the whole model.
            #expect(view._materializationCount == before + 1)
        }
        #expect(view._materializationCount == baseline + 4)
        #expect(view.currentSnapshot?.resourceOwners.count == 4)
        view.dismantleRenderSession()
        residency.ledger.handleMemoryPressure()
        #expect(await settle(clock) { residency.ledger.isAtBaseline })
    }

    @Test func resolutionsAreReleasedWhenTheModelStopsShowingTheirImages() async throws {
        let clock = ManualRenderClock()
        let executor = ParseExecutor()
        let png = try encodedPNG(width: 16, height: 16)
        let loader = FixtureImageLoader(data: png)
        let residency = isolatedImageResidency(maxPixelSize: 32)
        let view = imageTestView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 200), residency: residency,
            clock: clock, executor: executor
        )
        view.remoteImages = MarkdownImageConfiguration(loader: loader)
        view.blocks = MarkdownDocument(parsing: "![alt](https://images.test/dropped.png)").blocks
        #expect(await settle(clock) { view.currentSnapshot?.resourceOwners.count == 1 })
        #expect(view.imageCoordinator?.resolvedCount == 1)
        let backingID = try #require(view.currentSnapshot?.resourceOwners.first as? ImageOwnerLease).backingID
        #expect(residency.ledger.ownerCount(backingID) == 3)

        // The same session renders a model that no longer shows the image.
        let token = try #require(view.currentCommitToken)
        view.installSnapshot(
            model: RenderDisplayModel(runs: [], blocks: [], resources: [], accessibility: .init(roots: [])),
            configuration: MarkdownRenderConfiguration.default.snapshot(generation: 0), token: token
        )
        #expect(view.imageCoordinator?.resolvedCount == 0)
        // Only the completed cache still holds it; the session let go.
        #expect(residency.ledger.ownerCount(backingID) == 1)
        view.dismantleRenderSession()
        residency.ledger.handleMemoryPressure()
        #expect(await settle(clock) { residency.ledger.isAtBaseline })
    }

    /// The guard lives in the coordinator, so it has to be reached through a real
    /// downsized resolution, not by calling `insert` with a smaller key by hand.
    @Test func aDownsizedResolutionIsDisplayedButNeverPublishedToTheProcessCache() async throws {
        let clock = ManualRenderClock()
        let executor = ParseExecutor()
        let png = try encodedPNG(width: 64, height: 64)
        let first = FixtureImageLoader(data: png)
        let second = FixtureImageLoader(data: png)
        // A 64 px thumbnail costs 16384 bytes and a 32 px one 4096, so the full
        // extent is refused and the single smaller retry is what succeeds.
        let residency = isolatedImageResidency(hardLimit: 8192, cacheLimit: 8192, maxPixelSize: 64)
        let identity = MarkdownConfigurationID.semantic(namespace: "adversarial.downsized", version: 1)
        let source = "![alt](https://images.test/downsized.png)"

        let view = imageTestView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 200), residency: residency,
            clock: clock, executor: executor
        )
        view.remoteImages = MarkdownImageConfiguration(loader: first, configurationID: identity)
        view.blocks = MarkdownDocument(parsing: source).blocks
        #expect(await settle(clock) { view.currentSnapshot?.resourceOwners.count == 1 })
        #expect(await first.calls == 1)
        let backingID = try #require(view.currentSnapshot?.resourceOwners.first as? ImageOwnerLease).backingID
        // It really was downsized, and the session displays it.
        #expect(residency.ledger.accountedBytes == 4096)
        // Session resolution owner plus snapshot publication owner, and no cache owner.
        #expect(residency.ledger.ownerCount(backingID) == 2)
        #expect(residency.ledger.cacheCount == 0)

        // A second session with the same shared identity must not receive it.
        let other = imageTestView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 200), residency: residency,
            clock: clock, executor: executor
        )
        other.remoteImages = MarkdownImageConfiguration(loader: second, configurationID: identity)
        other.blocks = MarkdownDocument(parsing: source).blocks
        #expect(await settle(clock) { (other.imageCoordinator?.settledResolutionCount ?? 0) == 1 })
        #expect(await second.calls == 1)

        view.dismantleRenderSession()
        other.dismantleRenderSession()
        residency.ledger.handleMemoryPressure()
        #expect(await settle(clock) { residency.ledger.isAtBaseline })
    }

    /// A blockquote suppresses resource resolution for its whole subtree, so the
    /// materializer declines an owner that `resolvedResources` already acquired.
    /// The transaction must release only what was declined — not treat a partial
    /// hand-over as "nothing was retained" and uncharge the displayed image too.
    @Test func aQuotedImageDoesNotUnchargeTheImagesTheSnapshotDisplays() async throws {
        let clock = ManualRenderClock()
        let executor = ParseExecutor()
        let png = try encodedPNG(width: 16, height: 16)
        let loader = FixtureImageLoader(data: png)
        let residency = isolatedImageResidency(maxPixelSize: 32)
        let view = imageTestView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 200), residency: residency,
            clock: clock, executor: executor
        )
        view.remoteImages = MarkdownImageConfiguration(loader: loader)
        view.blocks = MarkdownDocument(parsing: """
        ![shown](https://images.test/quoted/shown.png)

        > ![quoted](https://images.test/quoted/quoted.png)
        """).blocks
        #expect(await settle(clock) { await loader.calls == 2 })
        #expect(await settle(clock) { (view.imageCoordinator?.settledResolutionCount ?? 0) == 2 })
        #expect(await settle(clock) { view.currentSnapshot?.resourceOwners.count == 1 })
        // Read the identity without retaining the lease: holding it here would keep
        // the backing charged and mask the teardown assertion below.
        let displayed = try #require(view.currentSnapshot?.resourceOwners.first as? ImageOwnerLease).backingID
        // Session resolution owner plus the snapshot's publication owner, and the
        // cache owner: the displayed image stays charged while it is on screen.
        #expect(residency.ledger.ownerCount(displayed) == 3)
        #expect(residency.ledger.accountedBytes > 0)
        view.dismantleRenderSession()
        residency.ledger.handleMemoryPressure()
        #expect(await settle(clock) { residency.ledger.isAtBaseline })
    }
}
