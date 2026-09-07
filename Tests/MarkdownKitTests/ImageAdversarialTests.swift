import Darwin
import Foundation
import MarkdownKit
@testable import MarkdownPlatformView
@testable import MarkdownRenderKit
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

    func finish(_ result: Result<MarkdownImagePayload, any Error>) {
        guard !self.pending.isEmpty else { return }
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
        _ residency: ImageResidencyConfiguration, sessions: Int = 5, perSession: Int = 20,
        configuration: (Int) -> MarkdownRemoteImageConfiguration
    ) -> [MarkdownLabelView] {
        (0 ..< sessions).map { session in
            let view = imageTestView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), residency: residency)
            view.remoteImages = configuration(session)
            view.blocks = MarkdownDocument(parsing: (0 ..< perSession).map {
                "![alt \(session)-\($0)](https://images.test/\(session)/\($0).png)"
            }.joined(separator: "\n\n")).blocks
            return view
        }
    }

    @Test func hundredImagesBoundTransfersAndReserveFullBodiesBeforeAnyNetworkStart() async {
        let loader = HeldImageLoader()
        let residency = isolatedImageResidency()
        let views = self.views(residency) { _ in MarkdownRemoteImageConfiguration(loader: loader) }
        #expect(await eventually { views.allSatisfy { $0.currentSnapshot != nil } })
        // Quiescence is the exact admitted/queued split, not a wall-clock or
        // yield-count guess: four of the hundred requests hold transfer slots and
        // the remaining ninety-six wait without any body reserved.
        #expect(await eventually {
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
        #expect(await eventually { await residency.permits.statistics.isEmpty })
        let final = await residency.permits.statistics
        #expect(final.peakTransfers == 4)
        #expect(final.peakDecodes == 0)
        #expect(residency.ledger.isAtBaseline)
    }

    @Test func hundredImagesDegradeInsteadOfExceedingResidencyAndReturnToBaseline() async throws {
        let png = try encodedPNG(width: 40, height: 40)
        let loader = FixtureImageLoader(data: png)
        // 32 px thumbnails cost alignUp(32 * 4, 64) * 32 = 4096 bytes each, so a
        // 24 KiB ledger can hold at most six of the hundred requests at once.
        let residency = isolatedImageResidency(hardLimit: 24 << 10, cacheLimit: 8 << 10, maxPixelSize: 32)
        let before = residentBytes()
        let views = self.views(residency) { _ in MarkdownRemoteImageConfiguration(loader: loader) }
        #expect(await eventually { views.allSatisfy { $0.currentSnapshot != nil } })
        #expect(await eventually { await loader.calls == 100 })
        #expect(await eventually { views.allSatisfy { $0.imageRequests.values.allSatisfy { $0 != .loading } } })
        let peak = await residency.permits.statistics
        #expect(peak.peakTransfers <= 4)
        #expect(peak.peakDecodes <= 2)
        #expect(peak.peakEncodedBytes <= 80 * 1024 * 1024)
        #expect(residency.ledger.accountedBytes <= 24 << 10)
        #expect(residency.ledger.cacheBytes <= 8 << 10)
        // The completion callback clears the request before the coalesced
        // re-materialization installs the attachment, so publication is observed
        // separately rather than assumed from the request state above.
        #expect(await eventually { views.contains { !($0.currentSnapshot?.resourceOwners.isEmpty ?? true) } })
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
        #expect(await eventually { residency.ledger.isAtBaseline })
        #expect(await eventually { await residency.permits.statistics.isEmpty })
        print("task-7 diagnostic: resident bytes \(before) -> \(residentBytes())")
    }

    @Test func defaultWrappersIsolateCompletedCacheButSharedSemanticIDReuses() async throws {
        let png = try encodedPNG(width: 16, height: 16)
        let residency = isolatedImageResidency(maxPixelSize: 32)
        let source = "![alt](https://images.test/shared.png)"
        let first = FixtureImageLoader(data: png)
        let second = FixtureImageLoader(data: png)

        let isolatedA = imageTestView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), residency: residency)
        isolatedA.remoteImages = MarkdownRemoteImageConfiguration(loader: first)
        isolatedA.blocks = MarkdownDocument(parsing: source).blocks
        #expect(await eventually { isolatedA.currentSnapshot?.resourceOwners.count == 1 })
        let isolatedB = imageTestView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), residency: residency)
        isolatedB.remoteImages = MarkdownRemoteImageConfiguration(loader: second)
        isolatedB.blocks = MarkdownDocument(parsing: source).blocks
        #expect(await eventually { isolatedB.currentSnapshot?.resourceOwners.count == 1 })
        #expect(await first.calls == 1)
        #expect(await second.calls == 1)

        let identity = MarkdownConfigurationID.semantic(namespace: "adversarial.images", version: 1)
        let third = FixtureImageLoader(data: png)
        let fourth = FixtureImageLoader(data: png)
        let sharedA = imageTestView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), residency: residency)
        sharedA.remoteImages = MarkdownRemoteImageConfiguration(loader: third, configurationID: identity)
        sharedA.blocks = MarkdownDocument(parsing: source).blocks
        #expect(await eventually { sharedA.currentSnapshot?.resourceOwners.count == 1 })
        let sharedB = imageTestView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), residency: residency)
        sharedB.remoteImages = MarkdownRemoteImageConfiguration(loader: fourth, configurationID: identity)
        sharedB.blocks = MarkdownDocument(parsing: source).blocks
        #expect(await eventually { sharedB.currentSnapshot?.resourceOwners.count == 1 })
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
        #expect(await eventually { residency.ledger.isAtBaseline })
    }

    @Test func replacedGenerationResultNeverPublishesOrWritesEitherCache() async throws {
        let png = try encodedPNG(width: 16, height: 16)
        let loader = PausedFixtureLoader()
        let residency = isolatedImageResidency(maxPixelSize: 32)
        let identity = MarkdownConfigurationID.semantic(namespace: "adversarial.generation", version: 1)
        let view = imageTestView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), residency: residency)
        var failures: [MarkdownResourceFailure] = []
        view.onResourceError = { failures.append($0) }
        view.remoteImages = MarkdownRemoteImageConfiguration(loader: loader, configurationID: identity)
        view.blocks = MarkdownDocument(parsing: "![alt](https://images.test/generation.png)").blocks
        #expect(await eventually { await loader.calls == 1 })
        let stale = try #require(view.currentCommitToken)

        view.remoteImages = MarkdownRemoteImageConfiguration(loader: loader, configurationID: identity)
        #expect(await eventually { view.currentCommitToken?.configurationGeneration == stale.configurationGeneration + 1 })
        #expect(await eventually { await loader.calls == 2 })

        await loader.finish(.success(MarkdownImagePayload(data: png, declaredMIMEType: "image/png")))
        for _ in 0 ..< 200 {
            await Task.yield()
        }
        #expect(view.currentSnapshot?.resourceOwners.isEmpty == true)
        #expect(residency.ledger.cacheCount == 0)
        #expect(residency.ledger.negativeCount == 0)
        #expect(failures.isEmpty)

        await loader.finish(.success(MarkdownImagePayload(data: png, declaredMIMEType: "image/png")))
        #expect(await eventually { view.currentSnapshot?.resourceOwners.count == 1 })
        #expect(residency.ledger.cacheCount == 1)
        view.dismantleRenderSession()
        residency.ledger.handleMemoryPressure()
        #expect(await eventually { residency.ledger.isAtBaseline })
    }

    @Test func negativeCacheHoldsOnlyDeterministicFailuresAndExpiresOnTheInjectedClock() async throws {
        let clock = ManualRenderClock()
        let residency = isolatedImageResidency(maxPixelSize: 32, clock: clock)
        let identity = MarkdownConfigurationID.semantic(namespace: "adversarial.negative", version: 1)
        let source = "![alt](https://images.test/negative.png)"

        let deterministic = PausedFixtureLoader()
        let view = imageTestView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), residency: residency)
        var failures: [MarkdownResourceFailure] = []
        view.onResourceError = { failures.append($0) }
        view.remoteImages = MarkdownRemoteImageConfiguration(loader: deterministic, configurationID: identity)
        view.blocks = MarkdownDocument(parsing: source).blocks
        #expect(await eventually { await deterministic.calls == 1 })
        try await deterministic.finish(.success(MarkdownImagePayload(data: encodedPNG(width: 8, height: 8), declaredMIMEType: "image/jpeg")))
        #expect(await eventually { failures.count == 1 })
        #expect(failures.first?.category == .typeMismatch)
        #expect(residency.ledger.negativeCount == 1)

        view.blocks = MarkdownDocument(parsing: "prefix\n\n\(source)").blocks
        #expect(await eventually { failures.count == 2 })
        #expect(failures.last?.category == .typeMismatch)
        #expect(await deterministic.calls == 1)

        clock.advance(by: .seconds(299))
        view.blocks = MarkdownDocument(parsing: "second\n\n\(source)").blocks
        #expect(await eventually { failures.count == 3 })
        #expect(await deterministic.calls == 1)
        clock.advance(by: .seconds(2))
        view.blocks = MarkdownDocument(parsing: "third\n\n\(source)").blocks
        #expect(await eventually { await deterministic.calls == 2 })

        // Connectivity failures are reported but never suppress the next attempt.
        await deterministic.finish(.failure(URLError(.timedOut)))
        #expect(await eventually { failures.count == 4 })
        #expect(failures.last?.category == .timedOut)
        // The expired deterministic entry was dropped by the lookup above and the
        // timeout added nothing, so the negative cache is empty.
        #expect(residency.ledger.negativeCount == 0)
        view.blocks = MarkdownDocument(parsing: "fourth\n\n\(source)").blocks
        #expect(await eventually { await deterministic.calls == 3 })
        view.dismantleRenderSession()
        await deterministic.finish(.failure(CancellationError()))
        #expect(await eventually { residency.ledger.isAtBaseline })
    }

    @Test func authorizationGateStopsOldTokenInstallCallbackAndLeaseCommit() throws {
        let residency = isolatedImageResidency()
        let registry = RenderSessionSinkRegistry()
        let view = imageTestView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), residency: residency)
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
            transaction.commit { _ in installed = true }
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
        enum Failure: Error { case materialization }
        let png = try encodedPNG(width: 16, height: 16)
        let residency = isolatedImageResidency(maxPixelSize: 32)
        let loader = FixtureImageLoader(data: png)
        let view = imageTestView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), residency: residency)
        view.remoteImages = MarkdownRemoteImageConfiguration(loader: loader)
        view.blocks = MarkdownDocument(parsing: "![alt](https://images.test/throwing.png)").blocks
        #expect(await eventually { view.currentSnapshot?.resourceOwners.count == 1 })
        var published: RenderSnapshot? = try #require(view.currentSnapshot)
        let charged = residency.ledger.accountedBytes

        view._materializationFailureForTesting = Failure.materialization
        let model = try #require(published).displayModel
        let token = try #require(view.currentCommitToken)
        view.installSnapshot(model: model, configuration: MarkdownRenderConfiguration.default.snapshot(generation: 0), token: token)
        #expect(view.currentSnapshot === published)
        #expect(view.lastRenderError == .preparationFailed)
        // Rolling back released only the owners this attempt admitted.
        #expect(residency.ledger.accountedBytes == charged)
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
        weak var observed = temporary
        temporary = nil
        #expect(observed == nil)
        #expect(!registry.withAuthorizedSink(for: vanishingToken) { _ in Issue.record("Disappeared sink installed a snapshot") })

        published = nil
        view.dismantleRenderSession()
        residency.ledger.handleMemoryPressure()
        #expect(await eventually { residency.ledger.isAtBaseline })
    }

    @Test func externallyRetainedOldSnapshotKeepsItsBackingChargedAcrossReplacement() async throws {
        let png = try encodedPNG(width: 16, height: 16)
        let residency = isolatedImageResidency(maxPixelSize: 32)
        let loader = FixtureImageLoader(data: png)
        let view = imageTestView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), residency: residency)
        view.remoteImages = MarkdownRemoteImageConfiguration(loader: loader)
        view.blocks = MarkdownDocument(parsing: "![alt](https://images.test/retained.png)").blocks
        #expect(await eventually { view.currentSnapshot?.resourceOwners.count == 1 })
        var retained: RenderSnapshot? = view.currentSnapshot
        let backingID = try #require(retained?.resourceOwners.first as? ImageOwnerLease).backingID
        // Session resolution owner, snapshot publication owner and cache owner.
        #expect(residency.ledger.ownerCount(backingID) == 3)

        view.blocks = MarkdownDocument(parsing: "plain text only").blocks
        #expect(await eventually { view.currentSnapshot?.resourceOwners.isEmpty == true })
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
}
