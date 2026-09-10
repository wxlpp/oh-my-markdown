import Foundation
@testable import MarkdownPlatformView
import Testing

@Suite(.timeLimit(.minutes(5)), .serialized)
struct ImageResourceCoordinatorTests {
    @Test func decodingConsumesEncodedReservationAndNormalizesThumbnail() async throws {
        let coordinator = ImageResourceCoordinator()
        let payload = await MainActor.run {
            MarkdownImagePayload(data: encodedTestImage(size: .init(width: 128, height: 64)).encodedData, declaredMIMEType: "image/png")
        }
        let reservation = try await coordinator.reserveEncodedBody(session: .init(rawValue: UUID()))
        let reserved = try await reservation.attach(ValidatedImageFactory.validate(payload))
        let decoded = try await ImageDecoder.decode(reserved, maxPixelSize: 32)
        #expect(decoded.backing.frames[0].width == 32)
        #expect(decoded.backing.frames[0].height == 16)
        #expect(decoded.backing.frames[0].bytesPerRow == 128)
        #expect(await coordinator.statistics.isEmpty)
        await reservation.consumedByDecoder()
        #expect(await coordinator.statistics.isEmpty)
    }

    @Test func combinedAdmissionNeverReservesBytesWhileWaitingForSessionTransferSlot() async throws {
        let coordinator = ImageResourceCoordinator()
        let session = RenderSessionID(rawValue: UUID())
        let first = try await coordinator.acquireTransferPermit(session: session)
        let second = try await coordinator.acquireTransferPermit(session: session)
        let queued = Task { try await coordinator.acquireTransfer(session: session) }
        await coordinator.settled { await coordinator.statistics.transferWaiters == 1 }
        #expect(await coordinator.statistics.encodedBytes == 0)
        await first.release()
        let admitted = try await queued.value
        #expect(await coordinator.statistics.encodedBytes == 20 * 1024 * 1024)
        await admitted.permit.release()
        #expect(await coordinator.statistics.encodedBytes == 20 * 1024 * 1024)
        await admitted.reservation.rejectAndRelease()
        await second.release()
        #expect(await coordinator.statistics.isEmpty)
    }

    @Test func transferAndDecodeSlotsAreFairAndCancellationIsIdempotent() async throws {
        let coordinator = ImageResourceCoordinator()
        let a = RenderSessionID(rawValue: UUID())
        let b = RenderSessionID(rawValue: UUID())
        let first = try await coordinator.acquireTransferPermit(session: a)
        let second = try await coordinator.acquireTransferPermit(session: a)
        let waiting = Task { try await coordinator.acquireTransferPermit(session: a) }
        await coordinator.settled { await coordinator.statistics.transferWaiters == 1 }
        let other = try await coordinator.acquireTransferPermit(session: b)
        #expect(await coordinator.statistics.transfers == 3)
        waiting.cancel()
        do { _ = try await waiting.value; Issue.record("Cancelled transfer admitted") } catch is CancellationError {}
        await first.release()
        await first.release()
        await second.release()
        await other.release()
        let decode = try await coordinator.acquireDecodePermit(session: a)
        let queued = Task { try await coordinator.acquireDecodePermit(session: a) }
        await coordinator.settled { await coordinator.statistics.decodeWaiters == 1 }
        await coordinator.cancelQueued(session: a)
        do { _ = try await queued.value; Issue.record("Revoked decode admitted") } catch is CancellationError {}
        await decode.release()
        #expect(await coordinator.statistics.isEmpty)
    }

    /// Drives real 17 MiB and 9 MiB bodies through the full admission path. The
    /// point is that an admitted request owns its whole body and a waiter owns
    /// nothing at all, so the schedule can only finish or stay unstarted.
    @Test(arguments: [(2, 17), (4, 9)])
    func fullBodySchedulesNeverLeaveAWaiterHoldingAPartialBody(count: Int, megabytes: Int) async throws {
        let coordinator = ImageResourceCoordinator()
        let encoded = try ValidatedImageFactory.validate(MarkdownImagePayload(
            data: paddedEncodedPNG(byteCount: megabytes * 1024 * 1024), declaredMIMEType: "image/png"
        ))
        #expect(encoded.data.count == megabytes * 1024 * 1024)
        var admissions: [ImageResourceCoordinator.TransferAdmission] = []
        var bodies: [ReservedEncodedImage] = []
        for _ in 0 ..< count {
            let admission = try await coordinator.acquireTransfer(session: .init(rawValue: UUID()))
            admissions.append(admission)
            try await bodies.append(admission.reservation.attach(encoded))
        }
        #expect(await coordinator.statistics.transfers == count)
        #expect(await coordinator.statistics.encodedBytes == count * 20 * 1024 * 1024)
        #expect(bodies.count == count)

        // Network is over; the bodies stay charged against the encoded ledger.
        for admission in admissions {
            await admission.permit.release()
        }
        #expect(await coordinator.statistics.transfers == 0)
        #expect(await coordinator.statistics.encodedBytes == count * 20 * 1024 * 1024)

        // Saturate the remaining allowance, then prove the next request waits with
        // no transfer slot, no reservation and no body of its own.
        var filler: [EncodedBodyReservation] = []
        while await coordinator.statistics.encodedBytes < 80 * 1024 * 1024 {
            try await filler.append(coordinator.reserveEncodedBody(session: .init(rawValue: UUID())))
        }
        let queued = Task { [coordinator] in try await coordinator.acquireTransfer(session: .init(rawValue: UUID())) }
        await coordinator.settled { await coordinator.statistics.transferWaiters == 1 }
        #expect(await coordinator.statistics.encodedBytes == 80 * 1024 * 1024)
        #expect(await coordinator.statistics.transfers == 0)

        for body in bodies {
            await body.reservation.consumedByDecoder()
        }
        // Consumption frees `count` allowances and the waiter takes exactly one.
        let admitted = try await queued.value
        #expect(await coordinator.statistics.encodedBytes == 80 * 1024 * 1024 - (count - 1) * 20 * 1024 * 1024)
        await admitted.permit.release()
        await admitted.reservation.rejectAndRelease()
        for reservation in filler {
            await reservation.rejectAndRelease()
        }
        #expect(await coordinator.statistics.isEmpty)
    }

    @Test func fifthEncodedReservationWaitsBeforeAnyBodyAndWakesOnRelease() async throws {
        let coordinator = ImageResourceCoordinator()
        let session = RenderSessionID(rawValue: UUID())
        var reservations: [EncodedBodyReservation] = []
        for _ in 0 ..< 4 {
            try await reservations.append(coordinator.reserveEncodedBody(session: session))
        }
        let queued = Task { try await coordinator.reserveEncodedBody(session: session) }
        await coordinator.settled { await coordinator.statistics.encodedWaiters == 1 }
        #expect(await coordinator.statistics.encodedBytes == 80 * 1024 * 1024)
        await reservations.removeFirst().rejectAndRelease()
        let admitted = try await queued.value
        #expect(await coordinator.statistics.encodedBytes == 80 * 1024 * 1024)
        await admitted.rejectAndRelease()
        for reservation in reservations {
            await reservation.rejectAndRelease()
        }
        #expect(await coordinator.statistics.isEmpty)
    }

    actor OrderRecorder {
        private(set) var values: [String] = []
        func record(_ value: String) {
            self.values.append(value)
        }
    }

    @Test func globalDecodeCeilingIsTwoAndWaitersWakeInOrder() async throws {
        let coordinator = ImageResourceCoordinator()
        let sessions = (0 ..< 3).map { _ in RenderSessionID(rawValue: UUID()) }
        var permits: [ImageResourcePermit] = []
        for session in sessions.prefix(2) {
            try await permits.append(coordinator.acquireDecodePermit(session: session))
        }
        let queued = Task { try await coordinator.acquireDecodePermit(session: sessions[2]) }
        await coordinator.settled { await coordinator.statistics.decodeWaiters == 1 }
        #expect(await coordinator.statistics.decodes == 2)
        #expect(await coordinator.statistics.peakDecodes == 2)
        await permits.removeFirst().release()
        let admitted = try await queued.value
        #expect(await coordinator.statistics.decodes == 2)
        #expect(await coordinator.statistics.peakDecodes == 2)
        await admitted.release()
        for permit in permits {
            await permit.release()
        }
        #expect(await coordinator.statistics.isEmpty)
    }

    @Test func waitersOnTheGlobalTransferLimitAreAdmittedInArrivalOrder() async throws {
        let coordinator = ImageResourceCoordinator()
        var holders: [ImageResourcePermit] = []
        for _ in 0 ..< 4 {
            try await holders.append(coordinator.acquireTransferPermit(session: .init(rawValue: UUID())))
        }
        let order = OrderRecorder()
        let first = Task { [coordinator] in
            let permit = try await coordinator.acquireTransferPermit(session: .init(rawValue: UUID()))
            await order.record("first")
            return permit
        }
        await coordinator.settled { await coordinator.statistics.transferWaiters == 1 }
        let second = Task { [coordinator] in
            let permit = try await coordinator.acquireTransferPermit(session: .init(rawValue: UUID()))
            await order.record("second")
            return permit
        }
        await coordinator.settled { await coordinator.statistics.transferWaiters == 2 }
        await holders.removeFirst().release()
        let firstPermit = try await first.value
        #expect(await order.values == ["first"])
        await holders.removeFirst().release()
        let secondPermit = try await second.value
        #expect(await order.values == ["first", "second"])
        #expect(await coordinator.statistics.peakTransfers == 4)
        await firstPermit.release()
        await secondPermit.release()
        for permit in holders {
            await permit.release()
        }
        #expect(await coordinator.statistics.isEmpty)
    }

    @Test func abandonedPermitsAndReservationsReturnEveryBudgetToBaseline() async throws {
        let coordinator = ImageResourceCoordinator()
        let session = RenderSessionID(rawValue: UUID())
        do {
            let permit = try await coordinator.acquireTransferPermit(session: session)
            let admission = try await coordinator.acquireTransfer(session: session)
            let reservation = try await coordinator.reserveEncodedBody(session: session)
            // Read the peaks while every grant is provably still alive, so the
            // assertion cannot depend on when ARC releases a discarded temporary.
            let peak = await coordinator.statistics
            #expect(peak.transfers == 2)
            #expect(peak.peakTransfers == 2)
            #expect(peak.peakEncodedBytes == 40 * 1024 * 1024)
            withExtendedLifetime((permit, admission, reservation)) {}
        }
        // Nothing was released explicitly; deinit alone returns every budget.
        await coordinator.settled { await coordinator.statistics.isEmpty }
    }

    @Test func cancellationRacingTheGrantHandoffNeverLeaksOrStrandsAPermit() async throws {
        let coordinator = ImageResourceCoordinator()
        for _ in 0 ..< 40 {
            var holders: [ImageResourcePermit] = []
            for _ in 0 ..< 4 {
                try await holders.append(coordinator.acquireTransferPermit(session: .init(rawValue: UUID())))
            }
            let waiter = Task { [coordinator] in try await coordinator.acquireTransferPermit(session: .init(rawValue: UUID())) }
            await coordinator.settled { await coordinator.statistics.transferWaiters == 1 }
            let released = holders.removeFirst()
            async let release: Void = released.release()
            waiter.cancel()
            await release
            if let granted = try? await waiter.value { await granted.release() }
            for permit in holders {
                await permit.release()
            }
            await coordinator.settled { await coordinator.statistics.isEmpty }
        }
    }

    @Test func revokedSessionQueueDoesNotDisturbActiveGrantsOfOtherSessions() async throws {
        let coordinator = ImageResourceCoordinator()
        let revoked = RenderSessionID(rawValue: UUID())
        let kept = RenderSessionID(rawValue: UUID())
        var holders: [ImageResourcePermit] = []
        for _ in 0 ..< 2 {
            try await holders.append(coordinator.acquireTransferPermit(session: revoked))
        }
        for _ in 0 ..< 2 {
            try await holders.append(coordinator.acquireTransferPermit(session: kept))
        }
        let queued = Task { [coordinator] in try await coordinator.acquireTransfer(session: revoked) }
        await coordinator.settled { await coordinator.statistics.transferWaiters == 1 }
        await coordinator.cancelQueued(session: revoked)
        do {
            _ = try await queued.value
            Issue.record("Revoked transfer was admitted")
        } catch is CancellationError {}
        #expect(await coordinator.statistics.transfers == 4)
        #expect(await coordinator.statistics.encodedBytes == 0)
        for permit in holders {
            await permit.release()
        }
        #expect(await coordinator.statistics.isEmpty)
    }

    @Test func cancellationBeforeDecodeReleasesTheDecodePermitAndEncodedReservation() async throws {
        let coordinator = ImageResourceCoordinator()
        let session = RenderSessionID(rawValue: UUID())
        let payload = try MarkdownImagePayload(data: encodedPNG(width: 32, height: 32), declaredMIMEType: "image/png")
        let reservation = try await coordinator.reserveEncodedBody(session: session)
        let reserved = try await reservation.attach(ValidatedImageFactory.validate(payload))
        let permit = try await coordinator.acquireDecodePermit(session: session)
        let gate = ResourceRenderGate()
        let task = Task {
            await gate.enter()
            return try await ImageDecoder.decode(reserved, maxPixelSize: 16, permit: permit)
        }
        await gate.waitForArrivals(1)
        task.cancel()
        await gate.open()
        do {
            _ = try await task.value
            Issue.record("Cancelled decode produced a backing")
        } catch is CancellationError {}
        await coordinator.settled { await coordinator.statistics.isEmpty }
    }

    @Test func oversizedBodiesAreRejectedByTheAttachedReservation() async throws {
        let coordinator = ImageResourceCoordinator()
        let reservation = try await coordinator.reserveEncodedBody(session: .init(rawValue: UUID()))
        #expect(reservation.byteLimit == 20 * 1024 * 1024)
        await #expect(throws: MarkdownResourceError.encodedLimit) {
            _ = try await reservation.attach(ValidatedImageFactory.validate(
                MarkdownImagePayload(data: Data(repeating: 0, count: 20 * 1024 * 1024 + 1), declaredMIMEType: "image/png")
            ))
        }
        await reservation.rejectAndRelease()
        #expect(await coordinator.statistics.isEmpty)
    }
}
