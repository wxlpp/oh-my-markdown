import Foundation

package actor ImageResourceCoordinator {
    package static let shared = ImageResourceCoordinator()
    package struct Statistics {
        package var transfers = 0
        package var decodes = 0
        package var encodedBytes = 0
        package var transferWaiters = 0
        package var decodeWaiters = 0
        package var encodedWaiters = 0
        /// Highest simultaneous grant this coordinator ever issued. A peak cannot be
        /// missed by sampling, so it is the ceiling proof the adversarial suites use.
        package var peakTransfers = 0
        package var peakDecodes = 0
        package var peakEncodedBytes = 0
        package var isEmpty: Bool {
            self.transfers == 0 && self.decodes == 0 && self.encodedBytes == 0 && self.transferWaiters == 0 && self.decodeWaiters == 0 && self.encodedWaiters == 0
        }
    }

    fileprivate enum Kind { case transfer, decode, encoded, transferAndEncoded }
    private struct Admission { let kind: Kind; let session: RenderSessionID }
    private struct Waiter {
        let id: UUID
        let admission: Admission
        let continuation: CheckedContinuation<ImageResourcePermit, any Error>
    }

    private var active: [UUID: Admission] = [:]
    private var waiting: [Waiter] = []
    private var peakTransfers = 0
    private var peakDecodes = 0
    private var peakEncoded = 0
    package var statistics: Statistics {
        Statistics(
            transfers: self.count(.transfer),
            decodes: self.count(.decode),
            encodedBytes: self.count(.encoded) * 20 * 1024 * 1024,
            transferWaiters: self.waiting.count(where: { $0.admission.kind == .transfer || $0.admission.kind == .transferAndEncoded }),
            decodeWaiters: self.waiting.count(where: { $0.admission.kind == .decode }),
            encodedWaiters: self.waiting.count(where: { $0.admission.kind == .encoded }),
            peakTransfers: self.peakTransfers,
            peakDecodes: self.peakDecodes,
            peakEncodedBytes: self.peakEncoded * 20 * 1024 * 1024
        )
    }

    private func notePeaks() {
        self.peakTransfers = max(self.peakTransfers, self.count(.transfer))
        self.peakDecodes = max(self.peakDecodes, self.count(.decode))
        self.peakEncoded = max(self.peakEncoded, self.count(.encoded))
    }

    package init() {}
    package struct TransferAdmission {
        package let permit: ImageResourcePermit
        package let reservation: EncodedBodyReservation
    }

    package func acquireTransfer(session: RenderSessionID) async throws -> TransferAdmission {
        let permit = try await acquire(.transferAndEncoded, session: session)
        // The combined grant already charges both limits. Splitting it into two
        // independently releasable records occurs in this actor turn, without await.
        self.active[permit.id] = Admission(kind: .transfer, session: session)
        let encodedID = UUID()
        self.active[encodedID] = Admission(kind: .encoded, session: session)
        self.notePeaks()
        let encodedPermit = ImageResourcePermit(coordinator: self, id: encodedID)
        return TransferAdmission(permit: permit, reservation: EncodedBodyReservation(permit: encodedPermit))
    }

    package func acquireTransferPermit(session: RenderSessionID) async throws -> ImageResourcePermit {
        try await self.acquire(.transfer, session: session)
    }

    package func acquireDecodePermit(session: RenderSessionID) async throws -> ImageResourcePermit {
        try await self.acquire(.decode, session: session)
    }

    package func reserveEncodedBody(session: RenderSessionID) async throws -> EncodedBodyReservation {
        try await EncodedBodyReservation(permit: self.acquire(.encoded, session: session))
    }

    private func count(_ kind: Kind, session: RenderSessionID? = nil) -> Int {
        self.active.values.count(where: {
            ($0.kind == kind || ($0.kind == .transferAndEncoded && (kind == .transfer || kind == .encoded)))
                && (session == nil || $0.session == session)
        })
    }

    private func canAdmit(_ admission: Admission) -> Bool {
        switch admission.kind {
        case .transfer: self.count(.transfer) < 4 && self.count(.transfer, session: admission.session) < 2
        case .decode: self.count(.decode) < 2 && self.count(.decode, session: admission.session) < 1
        case .encoded: self.count(.encoded) < 4
        case .transferAndEncoded: self.count(.transfer) < 4 && self.count(.transfer, session: admission.session) < 2 && self.count(.encoded) < 4
        }
    }

    private func acquire(_ kind: Kind, session: RenderSessionID) async throws -> ImageResourcePermit {
        try Task.checkCancellation()
        let id = UUID()
        let permit = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.waiting.append(Waiter(id: id, admission: Admission(kind: kind, session: session), continuation: continuation))
                self.drain()
            }
        } onCancel: { Task { await self.cancel(id) } }
        if Task.isCancelled { await permit.release(); throw CancellationError() }
        return permit
    }

    /// Arrival-ordered within each shared limit: a waiter contending for a limit is
    /// never overtaken by a later waiter contending for that same limit. Skipping is
    /// only across limits — a waiter blocked by its own session cap, or by a limit
    /// the skipped-over waiter does not share. Turning this into strict positional
    /// FIFO would let one saturated session block every other session behind it.
    private func drain() {
        var index = 0
        while index < self.waiting.count {
            let next = self.waiting[index]
            if self.canAdmit(next.admission) {
                self.waiting.remove(at: index)
                self.active[next.id] = next.admission
                self.notePeaks()
                next.continuation.resume(returning: ImageResourcePermit(coordinator: self, id: next.id))
            } else { index += 1 }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        self.waiting.remove(at: index).continuation.resume(throwing: CancellationError())
        self.drain()
    }

    package func cancelQueued(session: RenderSessionID) {
        for id in self.waiting.filter({ $0.admission.session == session }).map(\.id) {
            self.cancel(id)
        }
    }

    fileprivate func release(_ id: UUID) {
        guard self.active.removeValue(forKey: id) != nil else { return }
        self.drain()
    }
}

package final class ImageResourcePermit: Sendable {
    private let coordinator: ImageResourceCoordinator
    fileprivate let id: UUID
    fileprivate init(coordinator: ImageResourceCoordinator, id: UUID) {
        self.coordinator = coordinator; self.id = id
    }

    package func release() async {
        await self.coordinator.release(self.id)
    }

    deinit { Task { [coordinator, id] in await coordinator.release(id) } }
}

package actor EncodedBodyReservation {
    package nonisolated let byteLimit = 20 * 1024 * 1024
    private var permit: ImageResourcePermit?
    private var encoded: MarkdownEncodedImage?
    fileprivate init(permit: ImageResourcePermit) {
        self.permit = permit
    }

    package func attach(_ image: MarkdownEncodedImage) throws -> ReservedEncodedImage {
        guard self.permit != nil, self.encoded == nil, image.data.count <= self.byteLimit else { throw MarkdownResourceError.encodedLimit }
        self.encoded = image
        return ReservedEncodedImage(metadata: image.metadata, reservation: self)
    }

    package func imageForDecoder() throws -> MarkdownEncodedImage {
        guard let encoded else { throw CancellationError() }
        return encoded
    }

    package func rejectAndRelease() async {
        self.encoded = nil
        let releasing = self.permit
        self.permit = nil
        await releasing?.release()
    }

    package func consumedByDecoder() async {
        await self.rejectAndRelease()
    }
}

package struct ReservedEncodedImage {
    package let metadata: MarkdownImageMetadata
    package let reservation: EncodedBodyReservation
}
