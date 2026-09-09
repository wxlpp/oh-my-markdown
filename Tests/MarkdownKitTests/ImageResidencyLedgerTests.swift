import CoreGraphics
import Foundation
@testable import MarkdownPlatformView
@testable import MarkdownRenderKit
import Testing

@MainActor
@Suite(.serialized)
struct ImageResidencyLedgerTests {
    func decoded(size: Int = 4) throws -> DecodedImage {
        let context = try #require(CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let frame = try #require(context.makeImage())
        return try DecodedImage(backing: ImmutableCGImageBacking(frames: [frame]), decodedPixelSize: 4096)
    }

    func sourceKey(_ suffix: Int = 0, requestedPixelSize: Int = 4096) -> ImageSourceKey {
        ImageSourceKey(
            source: URL(string: "https://image.test/\(suffix)")!,
            configurationID: .semantic(namespace: "test", version: 1),
            requestedPixelSize: requestedPixelSize
        )
    }

    func key(_ suffix: Int = 0) -> ImageCacheKey {
        ImageCacheKey(
            source: URL(string: "https://image.test/\(suffix)")!,
            pixelWidth: 4,
            pixelHeight: 4,
            configurationID: .semantic(namespace: "test", version: 1)
        )
    }

    @Test func predecodeAccountingUsesAlignedBGRAAndRejectsOverflow() throws {
        #expect(ImageDecoder.pixelCost(width: 1, height: 2) == 128)
        #expect(ImageDecoder.pixelCost(width: Int.max, height: 2) == nil)
        #expect(ImageDecoder.pixelCost(width: 4096, height: 4096) == 64 * 1024 * 1024)
        let image = try decoded()
        #expect(image.backing.accountedPixelBytes == 256)
        #expect(image.backing.frames[0].bytesPerRow == 64)
        #expect(image.backing.frames[0].alphaInfo == .premultipliedFirst)
    }

    @Test func cacheEvictionCannotUnchargePublicationAndFinalReleaseIsIdempotent() throws {
        let ledger = ImageResidencyLedger(hardLimit: 1024, cacheLimit: 512)
        let reservation = try #require(ledger.reserveDecodedPixelBytes(256))
        let owned = try #require(try reservation.promote(self.decoded()))
        #expect(ledger.accountedBytes == 256)
        #expect(ledger.ownerCount(owned.backing.backingID) == 1)
        ledger.insert(owned, for: self.key(), indexedBy: self.sourceKey())
        let hit = try #require(ledger.completedImage(for: self.key()))
        #expect(ledger.ownerCount(hit.backing.backingID) == 3)
        ledger.handleMemoryPressure()
        #expect(ledger.cacheBytes == 0)
        #expect(ledger.accountedBytes == 256)
        owned.inFlightOwner.release()
        #expect(ledger.accountedBytes == 256)
        hit.inFlightOwner.release()
        hit.inFlightOwner.release()
        #expect(ledger.accountedBytes == 0)
    }

    @Test func reservationsReconcileBeforePublicationAndRollbackOnFailure() throws {
        let ledger = ImageResidencyLedger(hardLimit: 512, cacheLimit: 256)
        let first = try #require(ledger.reserveDecodedPixelBytes(256))
        let second = try #require(ledger.reserveDecodedPixelBytes(256))
        #expect(!first.reconcile(actualBytes: 257))
        #expect(ledger.reserveDecodedPixelBytes(1) == nil)
        second.cancel()
        second.cancel()
        #expect(first.reconcile(actualBytes: 320))
        #expect(ledger.accountedBytes == 320)
        first.cancel()
        #expect(ledger.accountedBytes == 0)
    }

    @Test func duplicatePhysicalBackingsStayChargedAndTransactionThrowReleasesOnlyNewOwners() throws {
        enum Failure: Error { case materialization }
        let ledger = ImageResidencyLedger(hardLimit: 1024, cacheLimit: 512)
        let first = try #require(try ledger.reserveDecodedPixelBytes(256)?.promote(self.decoded()))
        let second = try #require(try ledger.reserveDecodedPixelBytes(256)?.promote(self.decoded()))
        #expect(first.backing.backingID != second.backing.backingID)
        #expect(ledger.accountedBytes == 512)
        let session = RenderSessionID(rawValue: UUID())
        let firstSnapshot = UUID()
        let old = try #require(ledger.prepareSnapshotReplacement(
            session: session, oldSnapshotID: nil, newSnapshotID: firstSnapshot, images: [first]
        ))
        var oldOwners: [any ResourceResidencyOwner] = []
        old.commit { handOver, owners in
            oldOwners = owners
            handOver(owners)
        }
        let new = try #require(ledger.prepareSnapshotReplacement(
            session: session, oldSnapshotID: firstSnapshot, newSnapshotID: UUID(), images: [second]
        ))
        #expect(new.oldSnapshotID == firstSnapshot)
        do { try new.commit { _, _ in throw Failure.materialization } } catch Failure.materialization {}
        #expect(ledger.accountedBytes == 256)
        #expect(oldOwners.count == 1)
        oldOwners.removeAll()
        #expect(ledger.accountedBytes == 0)
    }

    @Test func thumbnailExtentCapsEverySideAtFourThousandNinetySixAndSixtyFourMiB() {
        #expect(ImageDecoder.thumbnailExtent(width: 10000, height: 5000, maxPixelSize: 8192).map { [$0.width, $0.height] } == [4096, 2048])
        #expect(ImageDecoder.thumbnailExtent(width: 20, height: 10, maxPixelSize: 4096).map { [$0.width, $0.height] } == [20, 10])
        #expect(ImageDecoder.thumbnailExtent(width: 0, height: 10, maxPixelSize: 32) == nil)
        let metadata = MarkdownImageMetadata(mimeType: "image/png", pixelWidth: 8192, pixelHeight: 8192, frameCount: 1, cumulativePixels: 0)
        #expect(ImageDecoder.reservationBytes(for: metadata, maxPixelSize: 8192) == 64 << 20)
        let ledger = ImageResidencyLedger()
        #expect(ledger.reserveDecodedPixelBytes((64 << 20) + 1) == nil)
        #expect(ledger.isAtBaseline)
    }

    @Test func reconciliationRejectionRetriesExactlyOneSmallerThumbnailThenDefers() async throws {
        let coordinator = ImageResourceCoordinator()
        let payload = try MarkdownImagePayload(data: encodedPNG(width: 128, height: 128), declaredMIMEType: "image/png")
        var offered: [Int] = []
        let reservation = try await coordinator.reserveEncodedBody(session: .init(rawValue: UUID()))
        let reserved = try await reservation.attach(ValidatedImageFactory.validate(payload))
        let decoded = try await ImageDecoder.decode(reserved, maxPixelSize: 64) { bytes in
            offered.append(bytes)
            return offered.count > 1
        }
        #expect(offered == [16384, 4096])
        #expect(decoded.backing.frames[0].width == 32)
        // The decoder halved on its own, so it must report 32 and not the 64 it
        // was asked for; the cache guard reads exactly this value.
        #expect(decoded.decodedPixelSize == 32)
        #expect(await coordinator.statistics.isEmpty)

        let second = try await coordinator.reserveEncodedBody(session: .init(rawValue: UUID()))
        let secondReserved = try await second.attach(ValidatedImageFactory.validate(payload))
        await #expect(throws: ImageDecodeFailure.budgetDeferred) {
            _ = try await ImageDecoder.decode(secondReserved, maxPixelSize: 64) { _ in false }
        }
        #expect(await coordinator.statistics.isEmpty)
    }

    @Test func completedCacheIsReachableBySourceAndEvictionClearsThatIndex() throws {
        let ledger = ImageResidencyLedger(hardLimit: 4096, cacheLimit: 2048)
        let owned = try #require(try ledger.reserveDecodedPixelBytes(256)?.promote(self.decoded()))
        ledger.insert(owned, for: self.key(), indexedBy: self.sourceKey())
        let hit = try #require(ledger.completedImage(for: self.sourceKey()))
        #expect(hit.backing.backingID == owned.backing.backingID)
        hit.inFlightOwner.release()
        ledger.evictCacheEntry(for: self.key())
        #expect(ledger.completedImage(for: self.sourceKey()) == nil)
        #expect(ledger.cacheCount == 0)
        owned.inFlightOwner.release()
        #expect(ledger.isAtBaseline)
    }

    @Test func negativeCacheKeepsOneHundredTwentyEightEntriesAndExpiresOnTheInjectedClock() {
        let clock = ManualRenderClock()
        let ledger = ImageResidencyLedger(clock: clock)
        func negative(_ index: Int) -> ImageSourceKey {
            ImageSourceKey(
                source: URL(string: "https://image.test/n/\(index)")!,
                configurationID: .semantic(namespace: "test", version: 1),
                requestedPixelSize: 4096
            )
        }
        for index in 0 ..< 129 {
            ledger.insertNegative(negative(index), category: .typeMismatch)
        }
        #expect(ledger.negativeCount == 128)
        #expect(ledger.negativeCategory(negative(0)) == nil)
        #expect(ledger.negativeCategory(negative(128)) == .typeMismatch)
        clock.advance(by: .seconds(299))
        #expect(ledger.negativeCategory(negative(128)) == .typeMismatch)
        clock.advance(by: .seconds(2))
        #expect(ledger.negativeCategory(negative(128)) == nil)
    }

    @Test func publishedBackingsBlockRoomMakingWhileCacheOnlyOwnershipYields() throws {
        let ledger = ImageResidencyLedger(hardLimit: 512, cacheLimit: 512)
        let published = try #require(try ledger.reserveDecodedPixelBytes(256)?.promote(self.decoded()))
        let cached = try #require(try ledger.reserveDecodedPixelBytes(256)?.promote(self.decoded()))
        ledger.insert(cached, for: self.key(1), indexedBy: self.sourceKey(1))
        cached.inFlightOwner.release()
        #expect(ledger.accountedBytes == 512)
        // The cache-only backing is evictable, so one more reservation fits.
        let third = try #require(ledger.reserveDecodedPixelBytes(256))
        #expect(ledger.cacheCount == 0)
        #expect(ledger.accountedBytes == 512)
        // Nothing evictable remains: the hard limit refuses instead of overcommitting.
        #expect(ledger.reserveDecodedPixelBytes(256) == nil)
        third.cancel()
        published.inFlightOwner.release()
        #expect(ledger.isAtBaseline)
    }

    @Test func promotingADuplicateBackingIdentityIsRefusedAndRollsBack() throws {
        let ledger = ImageResidencyLedger(hardLimit: 1024, cacheLimit: 512)
        let identity = UUID()
        let first = try #require(try ledger.reserveDecodedPixelBytes(256)?.promote(DecodedImage(backingID: identity, backing: self.decoded().backing, decodedPixelSize: 4096)))
        let reservation = try #require(ledger.reserveDecodedPixelBytes(256))
        #expect(try reservation.promote(DecodedImage(backingID: identity, backing: self.decoded().backing, decodedPixelSize: 4096)) == nil)
        #expect(ledger.accountedBytes == 256)
        first.inFlightOwner.release()
        #expect(ledger.isAtBaseline)
    }

    @Test func shippedResidencyDefaultsAreTheSpecifiedLimits() throws {
        let ledger = ImageResidencyLedger()
        #expect(ledger.hardLimit == 192 << 20)
        #expect(ledger.cacheLimit == 128 << 20)
        #expect(ImageResidencyLedger.shared.hardLimit == 192 << 20)
        // The shared instance is the only one wired to the process pressure signal.
        #expect(ImageResidencyLedger.shared.observesMemoryPressure)
        #expect(!ledger.observesMemoryPressure)
        #expect(ImageResidencyLedger.shared.cacheLimit == 128 << 20)
        // Three maximum-size images exactly fill the hard limit; the next byte is refused.
        var reservations: [DecodedPixelReservation] = []
        for _ in 0 ..< 3 {
            try reservations.append(#require(ledger.reserveDecodedPixelBytes(64 << 20)))
        }
        #expect(ledger.accountedBytes == 192 << 20)
        #expect(ledger.reserveDecodedPixelBytes(1) == nil)
        for reservation in reservations {
            reservation.cancel()
        }
        #expect(ledger.isAtBaseline)
    }

    @Test func aDownsizedRetryIsNeverServedToAFullExtentRequester() throws {
        let ledger = ImageResidencyLedger(hardLimit: 4096, cacheLimit: 4096)
        let owned = try #require(try ledger.reserveDecodedPixelBytes(256)?.promote(self.decoded()))
        let degraded = self.sourceKey(requestedPixelSize: 2048)
        ledger.insert(owned, for: self.key(), indexedBy: degraded)
        #expect(ledger.completedImage(for: self.sourceKey()) == nil)
        let hit = try #require(ledger.completedImage(for: degraded))
        #expect(hit.backing.backingID == owned.backing.backingID)
        hit.inFlightOwner.release()
        ledger.evictCacheEntry(for: self.key())
        #expect(ledger.completedImage(for: degraded) == nil)
        owned.inFlightOwner.release()
        #expect(ledger.isAtBaseline)
    }

    @Test func installClosureThatFailsAfterHandingOverKeepsTheNewOwnersAlive() throws {
        enum Failure: Error { case afterInstall }
        let ledger = ImageResidencyLedger(hardLimit: 1024, cacheLimit: 512)
        let owned = try #require(try ledger.reserveDecodedPixelBytes(256)?.promote(self.decoded()))
        let backingID = owned.backing.backingID
        let transaction = try #require(ledger.prepareSnapshotReplacement(
            session: .init(rawValue: UUID()), oldSnapshotID: nil, newSnapshotID: UUID(), images: [owned]
        ))
        #expect(ledger.ownerCount(backingID) == 1)
        var retained: [any ResourceResidencyOwner] = []
        do {
            try transaction.commit { handOver, owners in
                retained = owners
                handOver(owners)
                throw Failure.afterInstall
            }
        } catch Failure.afterInstall {}
        // Handing over transfers ownership, so the throw must not release them.
        #expect(ledger.ownerCount(backingID) == 1)
        #expect(retained.count == 1)
        retained.removeAll()
        #expect(ledger.isAtBaseline)
    }

    @Test func commitThatNeverHandsOverReleasesTheOwnersOnBothPaths() throws {
        enum Failure: Error { case materialization }
        let ledger = ImageResidencyLedger(hardLimit: 1024, cacheLimit: 512)

        // Success without a hand-over: nothing retained them, so they go back.
        let first = try #require(ledger.reserveDecodedPixelBytes(256)?.promote(self.decoded()))
        let firstID = first.backing.backingID
        let succeeding = try #require(ledger.prepareSnapshotReplacement(images: [first]))
        succeeding.commit { _, _ in }
        #expect(ledger.ownerCount(firstID) == 0)

        // Handing over the wrong objects is not a hand-over, so a throw still
        // rolls back. Under the earlier `{ _ in handedOver = true }` this leaked.
        let second = try #require(ledger.reserveDecodedPixelBytes(256)?.promote(self.decoded()))
        let secondID = second.backing.backingID
        let decoy = try #require(ledger.reserveDecodedPixelBytes(256)?.promote(self.decoded()))
        let throwing = try #require(ledger.prepareSnapshotReplacement(images: [second]))
        #expect(ledger.ownerCount(secondID) == 1)
        do {
            try throwing.commit { handOver, _ in
                handOver([decoy.inFlightOwner])
                throw Failure.materialization
            }
        } catch Failure.materialization {}
        #expect(ledger.ownerCount(secondID) == 0)
        decoy.inFlightOwner.release()
        #expect(ledger.isAtBaseline)
    }

    @Test func aLaterWrongHandOverCannotRevokeACorrectOne() throws {
        enum Failure: Error { case materialization }
        let ledger = ImageResidencyLedger(hardLimit: 1024, cacheLimit: 512)
        let owned = try #require(ledger.reserveDecodedPixelBytes(256)?.promote(self.decoded()))
        let decoy = try #require(ledger.reserveDecodedPixelBytes(256)?.promote(self.decoded()))
        let backingID = owned.backing.backingID
        let transaction = try #require(ledger.prepareSnapshotReplacement(images: [owned]))
        var retained: [any ResourceResidencyOwner] = []
        do {
            try transaction.commit { handOver, owners in
                retained = owners
                handOver(owners)
                handOver([decoy.inFlightOwner])
                throw Failure.materialization
            }
        } catch Failure.materialization {}
        // Without the latch the second call would drop the correct hand-over and
        // release an owner the caller already retained.
        #expect(ledger.ownerCount(backingID) == 1)
        #expect(retained.count == 1)
        retained.removeAll()
        decoy.inFlightOwner.release()
        #expect(ledger.isAtBaseline)
    }
}
